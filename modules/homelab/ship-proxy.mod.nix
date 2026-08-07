# nginx terminates TLS for <service>.su.is and proxies to local ports.
# Names resolve publicly (grey-cloud A records → water's tailnet IP) but
# only route inside the tailnet; there is no application auth.
#
# One wildcard *.su.is cert via DNS-01, since the host is not publicly
# reachable and HTTP-01 cannot work. Ports 80/443 never open publicly.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.ship-proxy;
  flake.nixosModules.ship-proxy =
    { config, lib, ... }:
    let
      inherit (lib.attrsets) optionalAttrs;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;

      cfg = config.shipProxy;
      inherit (lib.ship) topology;

      proxyTo = upstream: extra: {
        useACMEHost = cfg.domain;
        forceSSL = true;
        locations."/" = {
          proxyPass = upstream;
          proxyWebsockets = true;
        }
        // extra;
      };
      proxy = port: proxyTo "http://127.0.0.1:${toString port}";
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
          type = lib.types.nullOr lib.types.str;
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
            # The web seat is shell-capable, so the tailnet gate is enforced
            # here as well: without the source rules below, any local
            # service allowed 127.0.0.1 could reach it by Host header.
            // optionalAttrs config.cockpit.webEnable {
              "ai.${cfg.domain}" = proxyTo "http://${topology.seatWebAddr}:${toString topology.seatWebPort}" {
                # SSE responses must not be buffered. The denied addresses
                # are local pivots rather than tailnet peers.
                extraConfig = ''
                  proxy_buffering off;
                  deny 127.0.0.0/8;
                  deny ::1;
                  deny ${topology.hostTailnetAddr};
                  allow 100.64.0.0/10;
                  deny all;
                  # Dedicated source address so the seat's fence can admit
                  # nginx without admitting all of 127.0.0.1.
                  proxy_bind ${topology.seatIngressAddr};
                '';
              };
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
            # Default catch-all on :80 keeps the plain hostname (and the
            # tailnet IP / MagicDNS name) landing on the dashboard.
            // optionalAttrs config.services.homepage-dashboard.enable {
              homepage-catchall = {
                serverName = config.networking.hostName;
                default = true;
                locations."/" = {
                  proxyPass = "http://127.0.0.1:${toString config.services.homepage-dashboard.listenPort}";
                  proxyWebsockets = true;
                };
              };
            }
            # The wildcard DNS record resolves every name, used or not.
            # Unmatched HTTPS names answer nothing (444 = close without
            # responding); without an explicit :443 default, nginx would
            # fall back to the alphabetically first vhost — ai.su.is,
            # the web seat.
            // {
              https-catchall = {
                serverName = "_";
                default = true;
                onlySSL = true;
                useACMEHost = cfg.domain;
                extraConfig = "return 444;";
              };
            };
        };
      };
    };
}
