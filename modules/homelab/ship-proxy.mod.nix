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
      inherit (lib.lists) singleton;

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
                    type = lib.types.nullOr lib.types.port;
                    default = null;
                    description = "Upstream port on 127.0.0.1; or set root instead.";
                  };
                  upstream = mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "proxy_pass target in place of the port, which then serves only health checks.";
                  };
                  root = mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "A directory to serve as static files instead of proxying.";
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
            module. The nginx vhosts here derive
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
            # LAN DNS interception refuses direct authoritative queries.
            extraLegoFlags = singleton "--dns.propagation.disable-ans";
            environmentFile = cfg.acmeTokenFile;
            group = "nginx";
          };
        };

        # Let recursive DNS caches expire before abandoning a fresh challenge.
        systemd.services."acme-order-renew-${cfg.domain}".environment.CLOUDFLARE_PROPAGATION_TIMEOUT =
          "600";

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
                  if route.root != null then
                    {
                      useACMEHost = cfg.domain;
                      forceSSL = true;
                      inherit (route) root;
                    }
                  else
                    proxyTo
                      (if route.upstream != null then route.upstream else "http://127.0.0.1:${toString route.port}")
                      (
                        optionalAttrs (route.proxyExtra != "") {
                          extraConfig = route.proxyExtra;
                        }
                      )
                )
              )
            )
            # Plain hostname, tailnet IP and MagicDNS name on :80 go to the
            # homepage.
            // optionalAttrs (cfg.routes ? home) {
              home-catchall = {
                serverName = config.networking.hostName;
                default = true;
                locations."/".return = "302 https://${cfg.routes.home.subdomain}.${cfg.domain}$request_uri";
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
