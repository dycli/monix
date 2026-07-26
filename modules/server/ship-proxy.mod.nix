# Ship proxy aspect — pretty names for the ship's web UIs, tailnet-only.
# nginx terminates TLS for <service>.su.is and proxies to the local ports;
# the names resolve publicly (grey-cloud A records → fw0's tailnet IP,
# 100.102.113.74) but the address only routes inside the tailnet, so
# reachability is network-level, not auth-level. No tunnels: those are for
# things that must work without Tailscale (chat.su.is, ai.su.is).
#
# TLS is a single wildcard *.su.is Let's Encrypt cert via DNS-01 (the host
# is not publicly reachable, so HTTP-01 cannot work). lego talks to
# Cloudflare with a DNS-edit token supplied through shipProxy.acmeTokenFile
# (agenix). Ports 80/443 are never opened on the public firewall — the
# trusted tailscale0 interface is the only way in.
#
# Captain's side per new service: one grey-cloud A record in Cloudflare
# (<name>.su.is → 100.102.113.74). The wildcard cert already covers it.
{
  flake.nixosModules.ship-proxy =
    { config, lib, ... }:
    let
      inherit (lib.attrsets) optionalAttrs;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;

      cfg = config.shipProxy;

      proxy = port: extra: {
        useACMEHost = cfg.domain;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          proxyWebsockets = true;
        } // extra;
      };
    in
    {
      options.shipProxy = {
        enable = mkEnableOption "tailnet-only nginx front door with <service>.<domain> names";

        domain = mkOption {
          type = lib.types.str;
          default = "su.is";
          description = "Zone the service names live under (wildcard cert domain).";
        };

        acmeTokenFile = mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            agenix-decrypted file containing the Cloudflare API token
            (Zone → DNS → Edit for the zone) as
            CLOUDFLARE_DNS_API_TOKEN=<token>, readable by the acme user.
          '';
        };

        dashboardHost = mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "home.su.is";
          description = ''
            Full hostname for the homepage dashboard vhost; null = no
            dashboard vhost (the captain names this one).
          '';
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.acmeTokenFile != null;
            message = "shipProxy.enable requires shipProxy.acmeTokenFile";
          }
        ];

        security.acme = {
          acceptTerms = true;
          defaults.email = "dylan@dylandavid.com";
          certs.${cfg.domain} = {
            domain = "*.${cfg.domain}";
            dnsProvider = "cloudflare";
            environmentFile = cfg.acmeTokenFile;
            group = "nginx";
          };
        };

        services.nginx = {
          enable = true;
          recommendedProxySettings = true;
          recommendedTlsSettings = true;

          virtualHosts =
            optionalAttrs config.media.enable {
              "calibre.${cfg.domain}" = proxy 8083 {
                # Book uploads.
                extraConfig = "client_max_body_size 1g;";
              };
              "sab.${cfg.domain}" = proxy 8080 { };
              "radarr.${cfg.domain}" = proxy 7878 { };
              "sonarr.${cfg.domain}" = proxy 8989 { };
              "bazarr.${cfg.domain}" = proxy 6767 { };
              "prowlarr.${cfg.domain}" = proxy 9696 { };
            }
            // optionalAttrs config.services.jellyfin.enable {
              "jellyfin.${cfg.domain}" = proxy 8096 { };
            }
            // optionalAttrs config.services.home-assistant.enable {
              "ha.${cfg.domain}" = proxy 8123 { };
            }
            // optionalAttrs config.services.immich.enable {
              "immich.${cfg.domain}" = proxy 2283 {
                # Phone backup ships originals; immich checks size itself.
                extraConfig = ''
                  client_max_body_size 0;
                  proxy_read_timeout 600s;
                  proxy_send_timeout 600s;
                '';
              };
            }
            // optionalAttrs (cfg.dashboardHost != null && config.services.homepage-dashboard.enable) {
              ${cfg.dashboardHost} = proxy config.services.homepage-dashboard.listenPort { };
            }
            # Default catch-all on :80 keeps plain http://fw0 (and the
            # tailnet IP / MagicDNS name) landing on the dashboard, which
            # itself now lives on loopback :8082.
            // optionalAttrs config.services.homepage-dashboard.enable {
              homepage-catchall = {
                serverName = "fw0";
                default = true;
                locations."/" = {
                  proxyPass = "http://127.0.0.1:${toString config.services.homepage-dashboard.listenPort}";
                  proxyWebsockets = true;
                };
              };
            };
        };
      };
    };
}
