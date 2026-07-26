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

          # Header info widgets — read directly from the host, no services.
          widgets = [
            {
              resources = {
                cpu = true;
                memory = true;
                cputemp = true;
                # Only real mountpoints work here; /srv/media is a directory
                # on / until the RAID array lands — add it back when it
                # becomes its own filesystem.
                disk = [ "/" ];
              };
            }
          ];


          # Columns left→right and tiles top→bottom are both alphabetical
          # (captain's ordering) — list order here is display order.
          services = [
            {
              Arr = [
                {
                  Bazarr = {
                    href = "${host}:6767";
                    description = "Subtitles";
                    icon = "bazarr.png";
                  };
                }
                {
                  Prowlarr = {
                    href = "${host}:9696";
                    description = "Indexers";
                    icon = "prowlarr.png";
                  };
                }
                {
                  Radarr = {
                    href = "${host}:7878";
                    description = "Movies";
                    icon = "radarr.png";
                  };
                }
                {
                  SABnzbd = {
                    href = "${host}:8080";
                    description = "Downloads";
                    icon = "sabnzbd.png";
                  };
                }
                {
                  Sonarr = {
                    href = "${host}:8989";
                    description = "TV";
                    icon = "sonarr.png";
                  };
                }
              ];
            }
            {
              Media = [
                {
                  Calibre-Web = {
                    href = "${host}:8083";
                    description = "Ebooks — upload here, e-reader pulls via OPDS";
                    icon = "calibre-web.png";
                  };
                }
              ]
              ++ lib.lists.optional config.services.immich.enable {
                Immich = {
                  href = "${host}:2283";
                  description = "Family photos";
                  icon = "immich.png";
                };
              }
              ++ [
                {
                  Jellyfin = {
                    href = "${host}:8096";
                    description = "Movies & TV";
                    icon = "jellyfin.png";
                  };
                }
              ];
            }
            # Status column: just the UPS, fed by the ship-stats shim below
            # through homepage's customapi widget. (No native NUT widget in
            # homepage — its UPS widget wants PeaNUT, a whole extra web app,
            # for three fields.)
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

        # Stats → JSON shim for the UPS tile: socket-activated one-shot on
        # loopback :3494. GET /ups answers with upsc output as JSON. Dots in
        # NUT names become underscores (customapi mappings treat dots as
        # nesting); runtime is rounded to hours.
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
