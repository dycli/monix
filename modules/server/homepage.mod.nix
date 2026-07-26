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
              ];
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
