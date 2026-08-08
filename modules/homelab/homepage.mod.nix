# One dashboard tile per web UI, served on loopback :8082 behind the ship
# proxy, whose catch-all vhost keeps plain http://water working.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.homepage;
  flake.nixosModules.homepage =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.ship) fences topology;

      url =
        sub: port:
        if config.shipProxy.enable then
          "https://${sub}.${config.shipProxy.domain}"
        else
          "http://water:${toString port}";
    in
    {
      config = mkIf config.services.homepage-dashboard.enable {
        services.homepage-dashboard = {
          listenPort = 8082;
          openFirewall = false;

          # Host-header allowlist; homepage refuses every other name.
          allowedHosts = lib.strings.concatStringsSep "," (
            [
              config.networking.hostName
              topology.hostMagicDnsName
              topology.hostTailnetAddr # for browsers without MagicDNS
              "localhost"
              "127.0.0.1"
            ]
            ++ lib.lists.optional (
              config.shipProxy.enable && config.shipProxy.dashboardHost != null
            ) config.shipProxy.dashboardHost
          );

          settings = {
            title = "water";
            headerStyle = "clean";
            hideVersion = true;
          };

          widgets = [
            {
              resources = {
                cpu = true;
                memory = true;
                cputemp = true;
                # Only real mountpoints work here.
                disk = [ "/" ];
              };
            }
          ];

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
            # No native NUT widget, so this reads the shim below.
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
          Environment = [ "HOSTNAME=127.0.0.1" ];

          # The internet is allowed for the icon CDN.
          IPAddressAllow = fences.loopback ++ [ "100.64.0.0/10" ];
          IPAddressDeny = fences.privateRanges;
        };

        # GET /ups returns upsc output as JSON with dots in NUT names
        # replaced by underscores, since customapi reads a dot as nesting.
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
            IPAddressAllow = fences.loopback;
            IPAddressDeny = "any";
          };
          # awk only: printf and read are bash builtins, upsc is absolute.
          path = [ pkgs.gawk ];
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
      };
    };
}
