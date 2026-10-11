# One dashboard tile per web UI, served on loopback :8082 behind the ship
# proxy, whose catch-all vhost keeps plain http://water working.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.homepage;
  flake.nixosModules.homepage =
    { config, lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship) fences topology;

      url =
        name:
        let
          route = config.shipProxy.routes.${name};
        in
        "https://${route.subdomain}.${config.shipProxy.domain}";
    in
    {
      config = {
        services.homepage-dashboard = {
          enable = true;
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
            ++ lib.lists.optional (config.shipProxy.dashboardHost != null) config.shipProxy.dashboardHost
          );

          settings = {
            title = config.networking.hostName;
            headerStyle = "clean";
            hideVersion = true;
          };

          widgets = singleton {
            resources = {
              cpu = true;
              memory = true;
              cputemp = true;
              # Only real mountpoints work here.
              disk = singleton "/";
            };
          };

          services =
            singleton {
              Arr = [
                {
                  Bazarr = {
                    href = url "bazarr";
                    description = "Subtitles";
                    icon = "bazarr.png";
                  };
                }
                {
                  Prowlarr = {
                    href = url "prowlarr";
                    description = "Indexers";
                    icon = "prowlarr.png";
                  };
                }
                {
                  Radarr = {
                    href = url "radarr";
                    description = "Movies";
                    icon = "radarr.png";
                  };
                }
                {
                  SABnzbd = {
                    href = url "sab";
                    description = "Downloads";
                    icon = "sabnzbd.png";
                  };
                }
                {
                  Sonarr = {
                    href = url "sonarr";
                    description = "TV";
                    icon = "sonarr.png";
                  };
                }
              ];
            }
            ++ lib.lists.optional config.services.home-assistant.enable {
              Home =
                singleton {
                  "Home Assistant" = {
                    href = url "ha";
                    description = "Smart home";
                    icon = "home-assistant.png";
                  };
                }
                ++ singleton {
                  Frigate = {
                    href = "https://frigate.${config.shipProxy.domain}";
                    description = "Cameras";
                    icon = "frigate.png";
                  };
                };
            }
            ++ [
              {
                Media =
                  singleton {
                    Calibre-Web = {
                      href = url "calibre";
                      description = "eBooks";
                      icon = "calibre-web.png";
                    };
                  }
                  ++ lib.lists.optional config.services.immich.enable {
                    Immich = {
                      href = url "pix";
                      description = "Photos";
                      icon = "immich.png";
                    };
                  }
                  ++ [
                    {
                      Jellyfin = {
                        href = url "fin";
                        description = "Movies & TV";
                        icon = "jellyfin.png";
                      };
                    }
                    {
                      Seerr = {
                        href = url "q";
                        description = "Requests";
                        icon = "seerr.png";
                      };
                    }
                  ];
              }
            ];
        };

        systemd.services.homepage-dashboard.serviceConfig = {
          Environment = singleton "HOSTNAME=127.0.0.1";

          # The internet is allowed for the icon CDN.
          IPAddressAllow = fences.loopback ++ singleton fences.tailnet;
          IPAddressDeny = fences.privateRanges;
        };
      };
    };
}
