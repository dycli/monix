# Homepage aspect (gethomepage.dev) — one dashboard with a tile per web UI.
# Inert until a host sets `services.homepage-dashboard.enable`.
#
# Serves on loopback :8082 behind the ship proxy (ship-proxy.mod.nix), whose
# default catch-all vhost keeps plain http://fw0 working. Zero open firewall
# ports; the trusted tailscale0 interface is the only way in.
{
  flake.nixosModules.homepage =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;

      networkFences = import ../../lib/network-fences.nix;

      # Tile links: ship-proxy pretty names when the front door is up,
      # otherwise the tailnet short name + port.
      url =
        sub: port:
        if config.shipProxy.enable then
          "https://${sub}.${config.shipProxy.domain}"
        else
          "http://fw0:${toString port}";
    in
    {
      options.homepage.domain = lib.options.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public hostname the dashboard is served at through the tunnel.";
      };

      options.homepage.tunnelTokenFile = lib.options.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Cloudflare Tunnel connector token for exposing the dashboard at
          homepage.domain; null = tailnet-only, no public tunnel. The public
          hostname, origin (http://localhost:80), and the Cloudflare Access
          policy in front of it are managed in Cloudflare Zero Trust —
          put Access on it: the dashboard maps the ship's internals.
        '';
      };

      config = mkIf config.services.homepage-dashboard.enable {
        assertions = [
          {
            assertion = config.homepage.tunnelTokenFile == null || config.homepage.domain != null;
            message = "homepage.tunnelTokenFile requires homepage.domain";
          }
        ];

        services.homepage-dashboard = {
          # Loopback behind the ship proxy (nginx owns :80/:443; see
          # ship-proxy.mod.nix).
          listenPort = 8082;
          openFirewall = false;

          # Host-header allowlist (homepage refuses others).
          allowedHosts = lib.strings.concatStringsSep "," (
            [
              "fw0"
              "fw0.tailec4748.ts.net"
              "100.102.113.74" # raw tailnet IP, for browsers without MagicDNS
              "localhost"
              "127.0.0.1"
            ]
            ++ lib.lists.optional (config.homepage.domain != null) config.homepage.domain
            ++ lib.lists.optional (
              config.shipProxy.enable && config.shipProxy.dashboardHost != null
            ) config.shipProxy.dashboardHost
          );

          settings = {
            title = "fw0";
            headerStyle = "clean";
            hideVersion = true;
          };

          # Header info widgets — read directly from the host, no services.
          widgets = [
            {
              resources = {
                cpu = true;
                memory = true;
                cputemp = true;
                # Only real mountpoints work here; /srv/media is a directory
                # on / until the RAID array lands.
                disk = [ "/" ];
              };
            }
          ];


          # Columns and tiles are alphabetical; list order here is display order.
          services = [
            {
              Arr = [
                {
                  Bazarr = {
                    href = url "bazarr" 6767;
                    description = "Subtitles";
                    icon = "bazarr.png";
                  };
                }
                {
                  Prowlarr = {
                    href = url "prowlarr" 9696;
                    description = "Indexers";
                    icon = "prowlarr.png";
                  };
                }
                {
                  Radarr = {
                    href = url "radarr" 7878;
                    description = "Movies";
                    icon = "radarr.png";
                  };
                }
                {
                  SABnzbd = {
                    href = url "sab" 8080;
                    description = "Downloads";
                    icon = "sabnzbd.png";
                  };
                }
                {
                  Sonarr = {
                    href = url "sonarr" 8989;
                    description = "TV";
                    icon = "sonarr.png";
                  };
                }
              ];
            }
          ]
          ++ lib.lists.optional config.services.home-assistant.enable {
            Home = [
              {
                "Home Assistant" = {
                  href = url "ha" 8123;
                  description = "Smart home";
                  icon = "home-assistant.png";
                };
              }
            ]
            ++ lib.lists.optional config.shipCameras.enable {
              Frigate = {
                href = "https://frigate.${config.shipProxy.domain}";
                description = "Cameras";
                icon = "frigate.png";
              };
            };
          }
          ++ [
            {
              Media = [
                {
                  Calibre-Web = {
                    href = url "calibre" 8083;
                    description = "eBooks";
                    icon = "calibre-web.png";
                  };
                }
              ]
              ++ lib.lists.optional config.services.immich.enable {
                Immich = {
                  href = url "immich" 2283;
                  description = "Photos";
                  icon = "immich.png";
                };
              }
              ++ [
                {
                  Jellyfin = {
                    href = url "jellyfin" 8096;
                    description = "Movies & TV";
                    icon = "jellyfin.png";
                  };
                }
              ];
            }
            # Status column: UPS, fed by the ship-stats shim below via
            # homepage's customapi widget (no native NUT widget in homepage).
            {
              Status = lib.lists.optional config.alerts.ups.enable {
                UPS = {
                  description = "EcoFlow via NUT";
                  icon = "mdi-battery-charging";
                  widget = {
                    type = "customapi";
                    url = "http://127.0.0.1:3494/ups";
                    mappings = [
                      {
                        field = "battery_charge";
                        label = "battery";
                        suffix = "%";
                      }
                      {
                        field = "battery_runtime_hours";
                        label = "runtime";
                        suffix = "h";
                      }
                      {
                        field = "ups_status";
                        label = "status";
                        format = "text";
                      }
                    ];
                  };
                };
              };
            }
          ];
        };

        systemd.services.homepage-dashboard.serviceConfig = {
          # Loopback bind — reachability is nginx's job now.
          Environment = [ "HOSTNAME=127.0.0.1" ];

          # Same anti-pivot fence as the media stack: tailnet + loopback in,
          # public internet out (icon CDN), every private range denied.
          Slice = "services.slice";
          IPAddressAllow = [
            "100.64.0.0/10"
            "127.0.0.0/8"
            "::1"
          ];
          IPAddressDeny = networkFences.privateRanges;
        };

        # Stats → JSON shim for the UPS tile: socket-activated one-shot on
        # loopback :3494. GET /ups returns upsc output as JSON; dots in NUT
        # names become underscores (customapi mappings treat dots as nesting).
        systemd.sockets.ship-stats = mkIf config.alerts.ups.enable {
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "127.0.0.1:3494";
            Accept = true;
          };
        };
        systemd.services."ship-stats@" = mkIf config.alerts.ups.enable {
          description = "host stats as JSON for the homepage tiles";
          serviceConfig = {
            DynamicUser = true;
            StandardInput = "socket";
            StandardOutput = "socket";
            IPAddressAllow = [
              "127.0.0.0/8"
              "::1"
            ];
            IPAddressDeny = "any";
          };
          path = [
            pkgs.gawk
            pkgs.coreutils
          ];
          script = ''
            read -r _ reqpath _ || true
            while IFS= read -r line; do
              line=''${line%$'\r'}
              [ -z "$line" ] && break
            done

            case "$reqpath" in
              /ups)
                body=$(${pkgs.nut}/bin/upsc house 2>/dev/null | awk -F': ' '
                  $1 == "battery.charge"  { printf "\"battery_charge\":%s,", $2 }
                  $1 == "battery.runtime" { printf "\"battery_runtime_hours\":%.1f,", $2 / 3600 }
                  $1 == "ups.status"      { printf "\"ups_status\":\"%s\",", $2 }
                ')
                ;;
              *)
                body=""
                ;;
            esac

            body="{''${body%,}}"
            printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "''${#body}" "$body"
          '';
        };

        # Public ingress: Cloudflare Tunnel to homepage.domain. Origin +
        # Access policy live in Cloudflare Zero Trust; this unit only runs
        # the connector.
        systemd.services.homepage-tunnel = mkIf (config.homepage.tunnelTokenFile != null) {
          description = "Cloudflare Tunnel for the homepage dashboard";
          wantedBy = [ "multi-user.target" ];
          partOf = [ "homepage-dashboard.service" ];
          wants = [
            "network-online.target"
            "homepage-dashboard.service"
          ];
          after = [
            "network-online.target"
            "homepage-dashboard.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = [ "token:${config.homepage.tunnelTokenFile}" ];
            ExecStart = "${lib.meta.getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
          };
          environment = {
            TUNNEL_TRANSPORT_PROTOCOL = "http2";
          };
        };
      };
    };
}
