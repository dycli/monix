# Immich — photo library with on-server ML. Photos live in /srv/photos,
# separate from the media tree. ML models download from Hugging Face on
# first use.
#
# One name, pix.<domain>, two doors. On the tailnet the ship proxy serves
# the whole app. On the internet the same name rides a Cloudflare Tunnel
# into a second nginx vhost on loopback that forwards only what a shared
# link's page needs: the share routes, the web app's files, and the API
# routes the server itself marks as usable with a share key. Everything
# else, the login page above all, is 404 there. Immich's "external
# domain" setting (admin UI) makes generated links carry the name.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.immich;
  flake.nixosModules.immich =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) genAttrs;
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkDefault mkIf;
      inherit (lib.options) mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.immich;
      port = 2283;
      publicPort = 2284;
      upstream = "http://127.0.0.1:${toString port}";
      # Uploads from phones ship originals; immich checks size itself.
      proxyExtra = ''
        client_max_body_size 0;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
      '';

      # The share page: its routes (/share/<key>, /s/<slug>), the app shell's
      # static files, the public server endpoints, and the API routes whose
      # guard accepts a share key (sharedLink: true in the controllers).
      shared = [
        "/share/"
        "/s/"
        "/_app/"
        "= /custom.css"
        "= /manifest.json"
        "~ ^/(favicon|apple-icon|manifest-icon|dark_skeleton|light_skeleton)[^/]*$"
        "~ ^/api/server/(ping|version|version-history|features|config|media-types)$"
        "~ ^/api/shared-links/(me|login)$"
        "= /api/assets"
        "~ ^/api/assets/[0-9a-f-]+(/original|/thumbnail|/video/(playback|stream/.+))?$"
        "~ ^/api/albums/[0-9a-f-]+(/map-markers)?$"
        "~ ^/api/download/(info|archive)$"
        "= /api/search/metadata"
        "~ ^/api/timeline/buckets?$"
      ];
    in
    {
      options.immich.tunnelTokenFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Cloudflare Tunnel connector token for the public share door; null
          = tailnet-only. The hostname -> http://127.0.0.1:${toString publicPort}
          mapping is dashboard-side; no Cloudflare Access app on it, the
          share key is the gate.
        '';
      };

      config = {
        shipProxy.routes.pix = {
          inherit port proxyExtra;
        };

        services.nginx.virtualHosts.immich-public = {
          serverName = "pix.${config.shipProxy.domain}";
          listen = singleton {
            addr = "127.0.0.1";
            port = publicPort;
          };
          extraConfig = proxyExtra;
          locations =
            genAttrs shared (_: {
              proxyPass = upstream;
            })
            // {
              "/".return = "404";
            };
        };

        systemd.services.immich-tunnel = mkIf (cfg.tunnelTokenFile != null) {
          description = "Cloudflare Tunnel for shared photo links";
          wantedBy = singleton "multi-user.target";
          wants = [
            "network-online.target"
            "nginx.service"
          ];
          after = [
            "network-online.target"
            "nginx.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = singleton "token:${cfg.tunnelTokenFile}";
            ExecStart = "${getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
            # Cloudflare's edge and loopback only; 127.0.0.0/8 is denied
            # because the allow is a /24.
            IPAddressAllow = fences.loopback;
            IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          };
          environment.TUNNEL_TRANSPORT_PROTOCOL = "http2";
        };

        # Upstream only auto-creates its default /var/lib location, not a
        # custom mediaLocation.
        systemd.tmpfiles.rules = singleton "d ${config.services.immich.mediaLocation} 0750 immich immich -";

        services.immich = {
          enable = true;
          inherit port;
          # Bind wide so the tailnet reaches the port without the vhost.
          host = mkDefault "0.0.0.0";
          mediaLocation = mkDefault "/srv/photos";
        };

        # The internet falls through allowed, for model downloads. These
        # denies are not "any", so 127.0.0.0/8 must be named.
        systemd.services.immich-server.serviceConfig = {
          IPAddressAllow = fences.loopback ++ singleton fences.tailnet;
          IPAddressDeny = fences.privateRanges ++ singleton "127.0.0.0/8";
        };
        systemd.services.immich-machine-learning.serviceConfig = {
          IPAddressAllow = fences.loopback;
          IPAddressDeny = fences.privateRanges ++ singleton "127.0.0.0/8";
        };
      };
    };
}
