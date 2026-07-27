# Media stack aspect: Jellyfin plus the Usenet automation chain (Sonarr,
# Radarr, Bazarr, Prowlarr, SABnzbd), tailnet-only, plus Calibre-Web which
# may additionally open to the home LAN (see LAN EXCEPTION below). Inert
# until `media.enable`.
#
# Threat model: each service parses untrusted remote content, so all run
# unprivileged with openFirewall = false (tailnet-only via tailscale0), share
# only the `media` group, and are fenced off the home LAN and the agent-fleet
# bridge by a shared systemd IP allow/deny list.
#
# Storage: downloads/ and library/ share one filesystem (MEDIAROOT) so *arr
# imports are hardlinks, not copies. App-level wiring (Prowlarr↔*arr,
# credentials) is web-UI state, not Nix.
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

      # downloads/ (SABnzbd) and library/ (*arr, read by Jellyfin) share this
      # root for hardlink imports.
      mediaRoot = "/srv/media";

      # systemd checks IPAddressAllow BEFORE IPAddressDeny; unmatched traffic
      # is allowed. So: explicitly allow tailnet + loopback, deny every
      # private/link-local range (LAN, fleet bridge), and let the public
      # internet fall through allowed.
      egressFence = {
        Slice = "services.slice";
        IPAddressAllow = [
          "100.64.0.0/10" # tailnet (CGNAT range)
          "127.0.0.0/8" # loopback: inter-service APIs + resolved stub
          "::1"
        ];
        IPAddressDeny = networkFences.privateRanges;
      };

      # LAN EXCEPTION: the OPDS e-reader (ESP32) can't join the tailnet, so
      # calibreWebLan adds its LAN subnet to the allow list — which also lets
      # a compromised calibre-web reach the LAN (accepted trade; IP filters
      # are direction-blind). Every other private range, incl. the fleet
      # bridge, stays denied.
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
        # Every media-touching service runs with `media` as its primary
        # group. Prowlarr is excluded: it only brokers indexer searches.
        users.groups.media = { };

        # Setgid (2…) so created files inherit the media group. `d` rules
        # create-if-missing and never touch existing content — safe across
        # a future RAID re-mount.
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
        # allowConfigWrite defaults off (stateVersion >= 26.05): the ini is
        # READ-ONLY, stamped from Nix on every start, so the web UI cannot
        # save settings — everything must be declared here.
        services.sabnzbd = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :8080)

          secretFiles = mkIf (cfg.sabnzbdSecretsFile != null) (singleton cfg.sabnzbdSecretsFile);

          settings.misc = {
            # Bind everywhere; reachability is the firewall's job. Tailnet
            # counts as LOCAL, so the UI is reachable from it while
            # inet_exposure stays "none" (non-local access fully denied).
            host = "0.0.0.0";
            local_ranges = "127.0.0.1, ::1, 100.64.0.0/10";

            # SABnzbd rejects Host headers it doesn't know; teach it the
            # ship-proxy name when the front door is up.
            host_whitelist = lib.strings.concatStringsSep ", " (
              lib.lists.optional config.shipProxy.enable "sab.${config.shipProxy.domain}"
            );

            # Group-readable completes so the *arr importers can hardlink.
            download_dir = "${mediaRoot}/downloads/incomplete";
            complete_dir = "${mediaRoot}/downloads/complete";
            permissions = "775";
          };

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
        # E-reader pulls http://<fw0-lan-ip>:8083/opds (HTTP Basic auth);
        # books are kept as EPUB only, no conversion service.
        services.calibre-web = {
          enable = true;
          group = "media";
          openFirewall = false;
          listen = {
            # Bind everywhere (as SABnzbd above); tailnet via
            # trustedInterfaces, plus the LAN interface iff calibreWebLan is set.
            ip = "0.0.0.0";
            port = 8083;
          };
          options = {
            calibreLibrary = "${mediaRoot}/books";
            enableBookUploading = true;
          };
        };

        # calibre-web's upstream pre-start hard-fails without an existing
        # library, so seed an empty metadata.db (schema dumped from
        # `calibredb` 9.10) before that check runs.
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
        # VAAPI hw transcode: select in Jellyfin Dashboard → Playback →
        # VAAPI, /dev/dri/renderD128.
        users.users.jellyfin.extraGroups = [
          "render"
          "video"
        ];

        # Egress fence on every unit; Prowlarr too (indexers + *arrs on loopback).
        systemd.services.sonarr.serviceConfig = egressFence;
        systemd.services.radarr.serviceConfig = egressFence;
        systemd.services.bazarr.serviceConfig = egressFence;
        systemd.services.prowlarr.serviceConfig = egressFence;
        systemd.services.sabnzbd.serviceConfig = egressFence;
        systemd.services.jellyfin.serviceConfig = egressFence;
        # Widened fence — see LAN EXCEPTION above.
        systemd.services.calibre-web.serviceConfig = calibreWebFence;
      };
    };
}
