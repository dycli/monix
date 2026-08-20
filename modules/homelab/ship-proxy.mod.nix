# nginx terminates TLS for <service>.su.is and proxies to local ports.
# Names resolve publicly but only route inside the tailnet, and there is
# no application auth. One wildcard cert via DNS-01, since the host is not
# publicly reachable and HTTP-01 cannot work.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.ship-proxy;
  flake.nixosModules.ship-proxy =
    { config, lib, ... }:
    let
      inherit (lib.attrsets) mapAttrs' nameValuePair optionalAttrs;
      inherit (lib.options) mkOption;

      cfg = config.shipProxy;
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
        domain = mkOption {
          type = lib.types.str;
          default = "su.is";
          description = "Zone the service names live under (wildcard cert domain).";
        };

        acmeTokenFile = mkOption {
          type = lib.types.str;
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
            Full hostname for the homepage dashboard vhost; null disables
            the vhost.
          '';
        };

        routes = mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options = {
                  subdomain = mkOption {
                    type = lib.types.str;
                    default = name;
                    description = "Host label under the domain; defaults to the attr name.";
                  };
                  port = mkOption {
                    type = lib.types.port;
                    description = "Upstream port on 127.0.0.1.";
                  };
                  proxyExtra = mkOption {
                    type = lib.types.lines;
                    default = "";
                    description = "Extra nginx directives for this vhost's location.";
                  };
                };
              }
            )
          );
          default = { };
          description = ''
            Reverse-proxy routes, one per service, contributed by the owning
            module. The nginx vhosts here and the homepage tiles both derive
            from these, so a service's subdomain and port live in one place.
          '';
        };
      };

      config = {
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

          # Per-service routes (subdomain + port) come from each service's
          # own module via shipProxy.routes; the dashboard and catch-alls
          # stay here.
          virtualHosts =
            (
              cfg.routes
              |> mapAttrs' (
                _: route:
                nameValuePair "${route.subdomain}.${cfg.domain}" (
                  proxy route.port (
                    optionalAttrs (route.proxyExtra != "") {
                      extraConfig = route.proxyExtra;
                    }
                  )
                )
              )
            )
            // optionalAttrs (cfg.dashboardHost != null && config.services.homepage-dashboard.enable) {
              ${cfg.dashboardHost} = proxy config.services.homepage-dashboard.listenPort { };
            }
            # Plain hostname, tailnet IP and MagicDNS name on :80.
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
            # The wildcard DNS record resolves every name. Without an
            # explicit :443 default, nginx falls back to an application
            # vhost.
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
