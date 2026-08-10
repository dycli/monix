# Jellyfin and the Usenet automation chain (Sonarr, Radarr, Bazarr,
# Prowlarr, SABnzbd), tailnet-only, plus Calibre-Web. Indexer and *arr
# wiring is web-UI state. downloads/ and library/ share one filesystem so
# *arr imports hardlink.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.media;
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
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;

      cfg = config.media;
      inherit (lib.ship) fences hardened;

      mediaRoot = "/srv/media";

      # The internet is in neither list and so falls through allowed.
      egressFence = {
        IPAddressAllow = fences.loopback ++ [
          fences.tailnet
        ];
        # 127.0.0.0/8 is denied explicitly: this deny is not "any", so the
        # seat plane outside fences.loopback would otherwise be allowed.
        IPAddressDeny = fences.privateRanges ++ [ "127.0.0.0/8" ];
      };

      # The OPDS e-reader cannot join the tailnet. IP filters are
      # direction-blind, so this also lets calibre-web reach the LAN.
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
          type = types.nullOr types.str;
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
        unfreePackages = singleton "unrar";

        # Prowlarr is excluded: it only brokers indexer searches.
        users.groups.media = { };

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

        services.bazarr = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :6767)
        };

        services.prowlarr = {
          enable = true;
          openFirewall = false; # tailnet-only (UI on :9696)
        };

        # The ini is read-only, stamped from Nix on every start
        # (allowConfigWrite defaults off at stateVersion >= 26.05), so the
        # web UI cannot save settings and all of it must be declared here.
        services.sabnzbd = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :8080)

          secretFiles = mkIf (cfg.sabnzbdSecretsFile != null) (singleton cfg.sabnzbdSecretsFile);

          settings.misc = {
            # The tailnet counts as LOCAL, so the UI answers it while
            # inet_exposure stays "none".
            host = "0.0.0.0";
            local_ranges = "127.0.0.1, ::1, ${fences.tailnet}";

            # SABnzbd rejects Host headers it does not know.
            host_whitelist = lib.strings.concatStringsSep ", " (
              lib.lists.optional config.shipProxy.enable "sab.${config.shipProxy.domain}"
            );

            # Group-readable so the *arr importers can hardlink.
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

        # Ebooks: Calibre library, upload UI, OPDS feed at :8083/opds.
        services.calibre-web = {
          enable = true;
          group = "media";
          openFirewall = false;
          listen = {
            ip = "0.0.0.0";
            port = 8083;
          };
          options = {
            calibreLibrary = "${mediaRoot}/books";
            enableBookUploading = true;
          };
        };

        # calibre-web's pre-start hard-fails without an existing library.
        systemd.services.calibre-web.preStart = ''
          if [ ! -f ${mediaRoot}/books/metadata.db ]; then
            ${getExe' pkgs.sqlite "sqlite3"} ${mediaRoot}/books/metadata.db \
              < ${./calibre-library-init.sql}
          fi
        '';

        networking.firewall = mkIf (cfg.calibreWebLan != null) {
          interfaces.${cfg.calibreWebLan.interface}.allowedTCPPorts = [
            config.services.calibre-web.listen.port
          ];
        };

        services.jellyfin = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (web/API on :8096)
        };
        # VAAPI transcode must also be selected in Jellyfin's dashboard
        # under Playback, with /dev/dri/renderD128.
        users.users.jellyfin.extraGroups = [
          "render"
          "video"
        ];

        systemd.services.prowlarr.serviceConfig = egressFence;
        systemd.services.jellyfin.serviceConfig = egressFence;
        systemd.services.calibre-web.serviceConfig = calibreWebFence;

        # The media group lets every service write the whole tree, so each
        # unit is narrowed to the paths its job needs. SABnzbd and Bazarr
        # also take the vendor preset, shipping no isolation of their own.
        systemd.services.sabnzbd.serviceConfig =
          egressFence
          // hardened.vendor
          // {
            ReadWritePaths = [ "${mediaRoot}/downloads" ];
          };
        systemd.services.bazarr.serviceConfig =
          egressFence
          // hardened.vendor
          // {
            ReadWritePaths = [
              "${mediaRoot}/library"
              "/var/lib/bazarr" # its dataDir; the module declares no StateDirectory
            ];
          };
        systemd.services.sonarr.serviceConfig = egressFence // {
          ProtectSystem = "strict";
          ReadWritePaths = [
            "${mediaRoot}/downloads"
            "${mediaRoot}/library/tv"
          ];
        };
        systemd.services.radarr.serviceConfig = egressFence // {
          ProtectSystem = "strict";
          ReadWritePaths = [
            "${mediaRoot}/downloads"
            "${mediaRoot}/library/movies"
            # Radarr's module declares no StateDirectory (sonarr's does),
            # so strict mode makes its dataDir read-only unless named here.
            "/var/lib/radarr"
          ];
        };
        # Jellyfin gets no ProtectSystem=strict + ReadOnlyPaths: its "save
        # artwork into media folders" setting is web-UI state invisible
        # here, and read-only breaks artwork silently when it is on.
      };
    };
}
