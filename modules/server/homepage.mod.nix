# Homepage aspect — the ship's front door (gethomepage.dev). One dashboard
# with a tile per web UI so nobody memorizes ports: browse to http://fw0 and
# click. Inert until a host sets `services.homepage-dashboard.enable`.
#
# Same reachability posture as everything else: binds everywhere, zero open
# firewall ports, reached over the trusted tailscale0 interface. Port 80 so
# the address is just the hostname; the unit gets CAP_NET_BIND_SERVICE for
# that (it runs as DynamicUser, so no root involved).
#
# Tiles are static links (YAML from Nix, no web-UI state). Live-status
# widgets need per-service API keys — deliberately left for a later pass
# via environmentFile + agenix if wanted.
{
  flake.nixosModules.homepage =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkForce mkIf;

      networkFences = import ../../lib/network-fences.nix;

      # Tile links use the tailnet short name — resolvable from every device
      # that can reach the dashboard at all.
      host = "http://fw0";
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
          listenPort = 80;
          openFirewall = false; # tailnet-only

          # Host-header allowlist (homepage refuses others). Reachability is
          # already tailnet-only; this just names the ways we browse to it.
          allowedHosts = lib.strings.concatStringsSep "," (
            [
              "fw0"
              "fw0.tailec4748.ts.net"
              "100.102.113.74" # raw tailnet IP, for browsers without MagicDNS
              "localhost"
              "127.0.0.1"
            ]
            ++ lib.lists.optional (config.homepage.domain != null) config.homepage.domain
          );

          settings = {
            title = "fw0";
            headerStyle = "clean";
            hideVersion = true;
          };


          services = [
            {
              Media = [
                {
                  Jellyfin = {
                    href = "${host}:8096";
                    description = "movies & TV";
                    icon = "jellyfin.png";
                  };
                }
                {
                  Calibre-Web = {
                    href = "${host}:8083";
                    description = "ebooks — upload here, e-reader pulls via OPDS";
                    icon = "calibre-web.png";
                  };
                }
              ];
            }
            {
              Arr = [
                {
                  Radarr = {
                    href = "${host}:7878";
                    description = "movies";
                    icon = "radarr.png";
                  };
                }
                {
                  Sonarr = {
                    href = "${host}:8989";
                    description = "TV";
                    icon = "sonarr.png";
                  };
                }
                {
                  Bazarr = {
                    href = "${host}:6767";
                    description = "subtitles";
                    icon = "bazarr.png";
                  };
                }
                {
                  Prowlarr = {
                    href = "${host}:9696";
                    description = "indexers";
                    icon = "prowlarr.png";
                  };
                }
                {
                  SABnzbd = {
                    href = "${host}:8080";
                    description = "downloads";
                    icon = "sabnzbd.png";
                  };
                }
              ];
            }
            {
              Ship = [
                {
                  opencode = {
                    href = "https://ai.su.is";
                    description = "web cockpit seat (Cloudflare Access)";
                    icon = "mdi-console";
                  };
                }
              ]
              # System + UPS tiles, fed by the ship-stats shim below through
              # homepage's customapi widget. The header info widgets can't
              # sit inside a group and there's no custom header widget, so
              # system stats live here as a tile instead (captain's
              # preference: everything in one Ship column). Homepage shows at
              # most 4 fields per tile.
              ++ [
                {
                  System = {
                    description = "fw0";
                    icon = "mdi-chip";
                    widget = {
                      type = "customapi";
                      url = "http://127.0.0.1:3494/system";
                      mappings = [
                        {
                          field = "cpu_percent";
                          label = "cpu";
                          suffix = "%";
                        }
                        {
                          field = "mem_free_gib";
                          label = "mem free";
                          suffix = " GiB";
                        }
                        {
                          field = "disk_free_tb";
                          label = "disk free";
                          suffix = " TB";
                        }
                        {
                          field = "cpu_temp";
                          label = "temp";
                          suffix = "°C";
                        }
                      ];
                    };
                  };
                }
              ]
              # (No native NUT widget in homepage — its UPS widget wants
              # PeaNUT, a whole extra web app, for three fields.)
              ++ lib.lists.optional config.alerts.ups.enable {
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
          # Port 80 as an unprivileged DynamicUser. The upstream unit ships
          # an empty CapabilityBoundingSet; replace rather than merge (a
          # merged list would still contain the clearing empty entry).
          # PrivateUsers must go: inside its user namespace the ambient
          # capability doesn't reach the host's privileged ports (verified
          # live — listen EACCES on :80 with the caps in place).
          AmbientCapabilities = mkForce [ "CAP_NET_BIND_SERVICE" ];
          CapabilityBoundingSet = mkForce [ "CAP_NET_BIND_SERVICE" ];
          PrivateUsers = mkForce false;

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

        # Stats → JSON shim for the System and UPS tiles: socket-activated
        # one-shot on loopback :3494. GET /system reads /proc + hwmon + df;
        # GET /ups reads upsc. Dots in NUT names become underscores
        # (customapi mappings treat dots as nesting); runtime is rounded to
        # hours. CPU% samples /proc/stat over half a second per request.
        systemd.sockets.ship-stats = {
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "127.0.0.1:3494";
            Accept = true;
          };
        };
        systemd.services."ship-stats@" = {
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
              /system)
                read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
                sleep 0.5
                read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
                busy=$(((u2 + n2 + s2 + q2 + sq2 + st2) - (u1 + n1 + s1 + q1 + sq1 + st1)))
                total=$((busy + (i2 + w2) - (i1 + w1)))
                cpu=$(awk -v b="$busy" -v t="$total" 'BEGIN { printf "%.0f", t ? 100 * b / t : 0 }')

                mem=$(awk '/MemAvailable/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo)
                disk=$(df -B1 --output=avail / | tail -1 | awk '{ printf "%.2f", $1 / 1e12 }')
                temp=""
                for h in /sys/class/hwmon/hwmon*; do
                  if [ "$(cat "$h/name" 2>/dev/null)" = "k10temp" ]; then
                    temp=$(awk '{ printf "%.1f", $1 / 1000 }' "$h/temp1_input")
                  fi
                done
                body="\"cpu_percent\":$cpu,\"mem_free_gib\":$mem,\"disk_free_tb\":$disk,\"cpu_temp\":\"$temp\","
                ;;
              *)
                body=""
                ;;
            esac

            body="{''${body%,}}"
            printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "''${#body}" "$body"
          '';
        };

        # Public ingress: Cloudflare Tunnel to homepage.domain, same shape as
        # the matrix and opencode tunnels. Origin + Access policy live in
        # Cloudflare Zero Trust; this unit only runs the connector.
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
