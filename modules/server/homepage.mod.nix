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
    { config, lib, ... }:
    let
      inherit (lib.modules) mkForce mkIf;

      networkFences = import ../../lib/network-fences.nix;

      # Tile links use the tailnet short name — resolvable from every device
      # that can reach the dashboard at all.
      host = "http://fw0";
    in
    {
      config = mkIf config.services.homepage-dashboard.enable {
        services.homepage-dashboard = {
          listenPort = 80;
          openFirewall = false; # tailnet-only

          # Host-header allowlist (homepage refuses others). Reachability is
          # already tailnet-only; this just names the ways we browse to it.
          allowedHosts = lib.strings.concatStringsSep "," [
            "fw0"
            "fw0.tailec4748.ts.net"
            "localhost"
            "127.0.0.1"
          ];

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
              Automation = [
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
                  "llama-swap" = {
                    href = "${host}:8091";
                    description = "local inference";
                    icon = "mdi-brain";
                  };
                }
                {
                  opencode = {
                    href = "https://ai.su.is";
                    description = "web cockpit seat (Cloudflare Access)";
                    icon = "mdi-console";
                  };
                }
                {
                  Matrix = {
                    href = "https://chat.su.is";
                    description = "family chat (tuwunel)";
                    icon = "matrix.png";
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
      };
    };
}
