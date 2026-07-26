# Media stack aspect — Jellyfin plus the Usenet automation chain (Sonarr,
# Radarr, Bazarr, Prowlarr, SABnzbd), reachable over the tailnet and nowhere
# else, plus Calibre-Web (ebook library + OPDS feed) which may additionally
# be opened to the home LAN — see LAN EXCEPTION below. Inert until a host
# sets `media.enable`; imported on every host, so gated explicitly (same
# pattern as minecraft.mod.nix).
#
# PHILOSOPHY / THREAT MODEL. Six long-running network services that parse
# untrusted remote content (NNTP articles, indexer API responses, media
# containers, subtitle files). We assume any one of them can be compromised
# and make that lead nowhere:
#   - Reachability: every web UI has openFirewall = false. fw0 opens zero
#     public inbound ports; tailscale0 is the sole trusted interface, so the
#     UIs (and Jellyfin playback) are reached by being on the tailnet.
#   - Anti-pivot egress fence: the stack legitimately needs loopback (the
#     services talk to each other on 127.0.0.1) and the public internet
#     (Usenet provider over NNTPS, indexers, metadata databases, subtitle
#     providers) — but must NOT reach the home LAN or the agent-fleet microVM
#     bridge. A shared systemd IP allow/deny fence enforces exactly that.
#   - Blast radius: each service runs unprivileged under its own upstream
#     user; the shared `media` group is the only cross-service surface, and
#     it grants access to the media tree alone.
#
# STORAGE. One tree, one filesystem: MEDIAROOT below. Downloads and library
# live on the same filesystem ON PURPOSE — the *arr import step is then a
# hardlink (instant, no double disk). The services only ever see the path, so
# the planned move to a dedicated RAID array is: build array, copy tree,
# mount it at MEDIAROOT, done — no service config changes.
#
# App-level wiring (Prowlarr↔*arr connections, quality profiles, provider
# credentials, download dirs) is one-time state in each app's web UI, not Nix:
# upstream keeps that state in per-service SQLite/ini under /var/lib. The
# module's job is users, dirs, reachability, and the fence.
{
  flake.nixosModules.media =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) types;
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;

      cfg = config.media;
      networkFences = import ../../lib/network-fences.nix;

      # THE MEDIA TREE. downloads/ is SABnzbd's (incomplete + complete);
      # library/ is *arr-managed and what Jellyfin reads. Same filesystem =
      # hardlink imports (see STORAGE above).
      mediaRoot = "/srv/media";

      # Shared egress fence for the whole stack. systemd checks IPAddressAllow
      # BEFORE IPAddressDeny; anything matched by neither is ALLOWED. So:
      # allow the tailnet (UI/playback reachability) and loopback (the
      # services interconnect on 127.0.0.1, and DNS goes through the
      # systemd-resolved stub on 127.0.0.53), deny every private/link-local
      # range (home LAN, agent-fleet bridge 10.100.0.0/24 — inside
      # 10.0.0.0/8), and let the public internet (provider, indexers,
      # metadata, subtitles) fall through as allowed.
      egressFence = {
        Slice = "services.slice";
        IPAddressAllow = [
          "100.64.0.0/10" # tailnet (CGNAT range)
          "127.0.0.0/8" # loopback: inter-service APIs + resolved stub
          "::1"
        ];
        IPAddressDeny = networkFences.privateRanges;
      };

      # LAN EXCEPTION (calibre-web only). The e-reader that consumes the OPDS
      # feed is an ESP32 (crosspoint firmware) — it cannot join the tailnet,
      # so when media.calibreWebLan is set, its LAN subnet is added to the
      # allow list and the port is opened on that interface. systemd IP
      # filters are direction-blind, so this necessarily also lets a
      # compromised calibre-web reach the LAN — an accepted, documented trade
      # for reader access. The fleet bridge (10.100.0.0/24) and every other
      # private range stay denied.
      calibreWebFence = egressFence // {
        IPAddressAllow =
          egressFence.IPAddressAllow
          ++ lib.lists.optional (cfg.calibreWebLan != null) cfg.calibreWebLan.subnet;
      };
    in
    {
      options.media = {
        enable = mkEnableOption "the tailnet-only Jellyfin + Usenet automation media stack";

        sabnzbdSecretsFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Path to an agenix-decrypted INI (readable by the sabnzbd user)
            merged over the declarative SABnzbd settings at unit start.
            Carries misc.api_key / misc.nzb_key and the Usenet provider
            credentials (servers.newshosting.username/password).
          '';
        };

        calibreWebLan = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                interface = mkOption {
                  type = types.str;
                  description = "LAN interface to open the calibre-web port on.";
                  example = "enp191s0";
                };
                subnet = mkOption {
                  type = types.str;
                  description = "LAN subnet allowed through calibre-web's IP fence.";
                  example = "192.168.1.0/24";
                };
              };
            }
          );
          default = null;
          description = ''
            Open calibre-web (web UI + OPDS feed, :8083) to the home LAN so
            non-tailnet devices (the e-reader) can pull books. Null keeps it
            tailnet-only like the rest of the stack.
          '';
        };
      };

      config = mkIf cfg.enable {
        # THE SHARED GROUP. Every service that touches the media tree runs
        # with `media` as its primary group, so imports/rips/subtitles land
        # group-owned and every other member can read them. Prowlarr is
        # deliberately absent: it only brokers indexer searches and never
        # touches media files.
        users.groups.media = { };

        # THE MEDIA TREE. Setgid (2…) so everything created inside inherits
        # the media group; group-writable so any member service can import.
        # `d` rules create-if-missing and never touch existing content —
        # safe across the future RAID re-mount.
        systemd.tmpfiles.rules = [
          "d ${mediaRoot} 2775 root media -"
          "d ${mediaRoot}/downloads 2775 sabnzbd media -"
          "d ${mediaRoot}/downloads/incomplete 2775 sabnzbd media -"
          "d ${mediaRoot}/downloads/complete 2775 sabnzbd media -"
          "d ${mediaRoot}/library 2775 root media -"
          "d ${mediaRoot}/library/movies 2775 root media -"
          "d ${mediaRoot}/library/tv 2775 root media -"
          "d ${mediaRoot}/books 2775 calibre-web media -"
        ];

        # --- The librarians: decide WHAT to fetch, manage the library ---
        services.sonarr = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :8989)
        };
        services.radarr = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :7878)
        };

        # Subtitles: watches Sonarr/Radarr libraries, fetches matching subs.
        services.bazarr = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :6767)
        };

        # Indexer broker: holds the indexer accounts, fans searches out to
        # them, returns scored candidates to the *arrs (Newznab API).
        services.prowlarr = {
          enable = true;
          openFirewall = false; # tailnet-only (UI on :9696)
        };

        # --- The downloader: NNTP fetch, par2 repair, unpack ---
        # The new-style module keeps the ini READ-ONLY and stamps it from Nix
        # on every start (allowConfigWrite defaults off at stateVersion
        # >= 26.05) — the web UI cannot save settings, so everything is
        # declared here. Secrets (API keys, provider credentials) come in via
        # media.sabnzbdSecretsFile, merged with precedence at unit start.
        services.sabnzbd = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :8080)

          secretFiles = mkIf (cfg.sabnzbdSecretsFile != null) (singleton cfg.sabnzbdSecretsFile);

          settings.misc = {
            # Bind everywhere; reachability is the firewall's job (the fw0
            # pattern). The tailnet counts as LOCAL below, so the web UI is
            # open from the tailnet with inet_exposure staying at its "none"
            # default — non-local access remains fully denied (and firewalled).
            host = "0.0.0.0";
            local_ranges = "127.0.0.1, ::1, 100.64.0.0/10";

            # SABnzbd rejects Host headers it doesn't know; teach it the
            # ship-proxy name when the front door is up.
            host_whitelist = lib.strings.concatStringsSep ", " (
              lib.lists.optional config.shipProxy.enable "sab.${config.shipProxy.domain}"
            );

            # The media tree (see STORAGE in the header). Group-readable
            # completes so the *arr importers (media group) can hardlink.
            download_dir = "${mediaRoot}/downloads/incomplete";
            complete_dir = "${mediaRoot}/downloads/complete";
            permissions = "775";
          };

          # Newshosting (captain's provider, 2026-07-23). NNTPS on 563;
          # username/password merge in from the secrets INI.
          settings.servers.newshosting = {
            name = "newshosting";
            displayname = "Newshosting";
            host = "news.newshosting.com";
            port = 563;
            ssl = true;
            connections = 30;
            enable = true;
          };
        };

        # --- Ebooks: Calibre-format library, web upload UI, OPDS feed ---
        # The e-reader adds http://<fw0-lan-ip>:8083/opds (HTTP Basic auth)
        # and pulls books itself; books get in via the web UI's upload.
        # Library lives in the media tree; no conversion service — books are
        # kept as EPUB (the only format the reader takes).
        services.calibre-web = {
          enable = true;
          # Two build fixes for the current pin (drop once nixpkgs heals):
          # tests disabled because nativeCheckInputs pull in scholarly →
          # free-proxy → pip-chill and pip-chill is unbuildable (imports
          # pkg_resources, removed in setuptools 82) — none of that chain is
          # in the runtime closure; and two more overly-tight upstream
          # version pins relaxed (nixpkgs already relaxes eleven others).
          package = pkgs.calibre-web.overridePythonAttrs (old: {
            doCheck = false;
            pythonRelaxDeps = old.pythonRelaxDeps ++ [
              "chardet"
              "certifi"
            ];
          });
          group = "media";
          openFirewall = false;
          listen = {
            # Bind everywhere; reachability is the firewall's job (same
            # pattern as SABnzbd above): tailnet via trustedInterfaces, plus
            # the LAN interface iff calibreWebLan is set.
            ip = "0.0.0.0";
            port = 8083;
          };
          options = {
            calibreLibrary = "${mediaRoot}/books";
            enableBookUploading = true;
          };
        };

        # First-boot library bootstrap. calibre-web cannot create a Calibre
        # library and its upstream pre-start hard-fails without one, so seed
        # an empty metadata.db (schema dumped from `calibredb` 9.10, checked
        # in as SQL text) before the upstream check runs. preStart is
        # mkBefore'd onto ExecStartPre by the systemd module, and runs as the
        # calibre-web user, who owns the books dir.
        systemd.services.calibre-web.preStart = ''
          if [ ! -f ${mediaRoot}/books/metadata.db ]; then
            ${pkgs.sqlite}/bin/sqlite3 ${mediaRoot}/books/metadata.db \
              < ${./calibre-library-init.sql}
          fi
        '';

        networking.firewall = mkIf (cfg.calibreWebLan != null) {
          interfaces.${cfg.calibreWebLan.interface}.allowedTCPPorts = [
            config.services.calibre-web.listen.port
          ];
        };

        # --- Playback ---
        services.jellyfin = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (web/API on :8096)
        };
        # Hardware transcode (VAAPI) on the Strix Halo iGPU. Mesa is already
        # live on fw0 (Vulkan inference); Jellyfin just needs the device
        # nodes. Selected inside Jellyfin: Dashboard → Playback → VAAPI,
        # /dev/dri/renderD128.
        users.users.jellyfin.extraGroups = [
          "render"
          "video"
        ];

        # HARDENING — the fence (see header) on every unit in the stack.
        # Prowlarr runs with DynamicUser and no media access; it still gets
        # the fence (it talks only to indexers + the *arrs on loopback).
        systemd.services.sonarr.serviceConfig = egressFence;
        systemd.services.radarr.serviceConfig = egressFence;
        systemd.services.bazarr.serviceConfig = egressFence;
        systemd.services.prowlarr.serviceConfig = egressFence;
        systemd.services.sabnzbd.serviceConfig = egressFence;
        systemd.services.jellyfin.serviceConfig = egressFence;
        # calibre-web gets the widened fence — see LAN EXCEPTION above.
        systemd.services.calibre-web.serviceConfig = calibreWebFence;
      };
    };
}
