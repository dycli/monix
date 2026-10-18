# The wall frame's homepage at https://frame.<domain>: one Immich album as
# a slideshow with the time, the week's calendar, the forecast and the air
# indoors, served by ./frame. The same server answers https://home.<domain>
# with the house's homepage: the services, Water's health and the same
# board. The frame (a rooted Frameo on the IoT VLAN) cannot join the
# tailnet, so the server also listens on the LAN port directly; the page
# carries photos and the board only, never the Immich key or CalDAV login.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.frame;
  flake.nixosModules.frame =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) mapAttrsToList optionalAttrs;
      inherit (lib.strings) concatStringsSep toJSON;
      inherit (lib.lists) optional singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.frame;
      port = 8970;
      frame = lib.ship.rustTool pkgs { src = ./frame; };
    in
    {
      options.frame = {
        immichKeyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Immich API key with album.read, asset.read and asset.view;
            null = off.
          '';
        };
        album = mkOption {
          type = types.str;
          description = "Name of the Immich album the frame shows.";
        };
        calendarCredentialsFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "yeoman's CalDAV accounts JSON; null = no calendar.";
        };
        weather = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "`latitude,longitude` for the forecast; null = none.";
          example = "43.07,-70.76";
        };
        air = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Address of an AirGradient monitor on the frame's subnet; null = none.";
          example = "192.168.30.191";
        };
        cameras = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "go2rtc streams the page shows live: stream name → label.";
          example = {
            tapo1 = "Living room";
          };
        };
        services = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                name = mkOption { type = types.str; };
                about = mkOption {
                  type = types.str;
                  default = "";
                };
                icon = mkOption {
                  type = types.str;
                  default = "";
                  description = "Name in the dashboard-icons set, e.g. `sonarr`.";
                };
                route = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "shipProxy route the service is reached by.";
                };
                url = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Address to open, for a service without a route.";
                };
                check = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Loopback address to check; defaults to the route's port.";
                };
              };
            }
          );
          default = [ ];
          description = "Services the homepage lists and checks, in order.";
        };
        disks = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                label = mkOption { type = types.str; };
                path = mkOption { type = types.str; };
              };
            }
          );
          default = [ ];
          description = "Filesystems the homepage shows, in order.";
          example = [
            {
              label = "System";
              path = "/";
            }
          ];
        };
        lan = mkOption {
          type = types.submodule {
            options = {
              interface = mkOption {
                type = types.str;
                description = "LAN interface to open the frame's port on.";
                example = "enp191s0";
              };
              subnet = mkOption {
                type = types.str;
                description = "LAN subnet allowed through the server's IP fence.";
                example = "192.168.1.0/24";
              };
            };
          };
          description = "Where the frame reaches the page, at http://<host>:${toString port}.";
        };
      };

      config = mkIf (cfg.immichKeyFile != null) {
        shipProxy.routes.frame.port = port;
        shipProxy.routes.home.port = port;

        networking.firewall.interfaces.${cfg.lan.interface}.allowedTCPPorts = singleton port;

        systemd.services.frame = {
          description = "The wall frame's homepage";
          wantedBy = singleton "multi-user.target";
          after = singleton "immich-server.service";
          environment = {
            FRAME_LISTEN = "0.0.0.0:${toString port}";
            FRAME_IMMICH = "http://127.0.0.1:2283";
            FRAME_IMMICH_KEY_FILE = "%d/immich-key";
            FRAME_ALBUM = cfg.album;
            FRAME_TZ = config.time.timeZone;
          }
          // optionalAttrs (cfg.calendarCredentialsFile != null) {
            FRAME_CALDAV_FILE = "%d/caldav";
          }
          // optionalAttrs (cfg.weather != null) {
            FRAME_WEATHER = cfg.weather;
          }
          // optionalAttrs (cfg.air != null) {
            FRAME_AIR = cfg.air;
          }
          // optionalAttrs (cfg.services != [ ]) {
            FRAME_SERVICES =
              cfg.services
              |> map (
                s:
                let
                  route = config.shipProxy.routes.${s.route};
                in
                {
                  inherit (s) name about icon;
                  url = if s.route != null then "https://${route.subdomain}.${config.shipProxy.domain}" else s.url;
                  check = if s.check != null then s.check else "http://127.0.0.1:${toString route.port}/";
                }
              )
              |> toJSON;
          }
          // optionalAttrs (cfg.disks != [ ]) {
            FRAME_DISKS = cfg.disks |> map (d: "${d.label}=${d.path}") |> concatStringsSep ",";
          }
          // optionalAttrs (cfg.cameras != { }) {
            # The Tapos pan and tilt through Frigate's ONVIF link.
            FRAME_CAMERAS =
              cfg.cameras
              |> mapAttrsToList (
                id: name: {
                  inherit id name;
                  turns = config.shipCameras.tapo ? ${id};
                }
              )
              |> toJSON;
            FRAME_GO2RTC = "http://127.0.0.1:1984";
            FRAME_FRIGATE = "ws://127.0.0.1:5000/ws";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            DynamicUser = true;
            # Photos shrunk to the screen, kept across restarts.
            CacheDirectory = "frame";
            # The homepage reads Water's load, memory and uptime from /proc.
            ProcSubset = "all";
            ExecStart = getExe frame;
            LoadCredential = [
              "immich-key:${cfg.immichKeyFile}"
            ]
            ++ optional (cfg.calendarCredentialsFile != null) "caldav:${cfg.calendarCredentialsFile}";
            Restart = "on-failure";
            SocketBindDeny = "any";
            SocketBindAllow = singleton "tcp:${toString port}";
            # Immich, go2rtc and Frigate on loopback, the frame on its subnet, and the internet
            # for CalDAV and Open-Meteo; the rest of the LAN stays shut.
            # Allow is checked first, so the frame's subnet gets through.
            IPAddressAllow = fences.loopback ++ singleton cfg.lan.subnet;
            IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          };
        };
      };
    };
}
