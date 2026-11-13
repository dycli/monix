# hob, the house's backend (dycli/hob): the cameras, the photo album, the
# forecast, the air indoors and the calendar behind one API and MCP. The
# house's settings are in services.hob (here, homelab.mod.nix and the
# host's credentials); this module adds what is particular to this ship:
# - the wall frame's address: the frame (a rooted Frameo on the IoT VLAN)
#   cannot join the tailnet, so hob listens on its LAN port too, opened to
#   that subnet only; the frame's page is hob's own (`/`);
# - frame.<domain>, the tailnet's address for the same server, where
#   Libri's cards load pictures and video, and Libri's MCP entry;
# - the fence: loopback (Immich, go2rtc, Frigate), the frame's subnet and
#   the internet (CalDAV, Open-Meteo), never the rest of the LAN.
{ self, inputs, ... }:
{
  flake.nixosModules.lab = self.nixosModules.hob;
  flake.nixosModules.hob =
    { config, lib, ... }:
    let
      inherit (lib.attrsets) mapAttrsToList;
      inherit (lib.lists) singleton;
      inherit (lib.options) mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.hob;
      inherit (config.services.hob) port;
      route = config.shipProxy.routes.frame;
    in
    {
      imports = singleton inputs.hob.nixosModules.default;

      options.hob = {
        cameras = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Frigate cameras hob shows: name → label. The Tapos pan and tilt.";
          example = {
            tapo1 = "Living room";
          };
        };
        lan = mkOption {
          type = types.submodule {
            options = {
              interface = mkOption {
                type = types.str;
                description = "LAN interface to open hob's port on.";
                example = "enp191s0";
              };
              subnet = mkOption {
                type = types.str;
                description = "The frame's subnet, allowed through hob's IP fence.";
                example = "192.168.30.0/24";
              };
            };
          };
          description = "Where the wall frame reaches hob, at http://<host>:${toString port}.";
        };
      };

      config = {
        services.hob = {
          enable = true;
          address = "0.0.0.0";
          publicUrl = "https://${route.subdomain}.${config.shipProxy.domain}";
          cameras = lib.mkIf (cfg.cameras != { }) {
            list = mapAttrsToList (id: name: {
              inherit id name;
              # The Tapos turn through Frigate's ONVIF link.
              turns = config.shipCameras.tapo ? ${id};
            }) cfg.cameras;
            go2rtcUrl = "http://127.0.0.1:1984";
            frigateUrl = "http://127.0.0.1:5000";
          };
        };

        shipProxy.routes.frame.port = port;
        networking.firewall.interfaces.${cfg.lan.interface}.allowedTCPPorts = singleton port;

        systemd.services.hob = {
          after = singleton "immich-server.service";
          serviceConfig = {
            SocketBindDeny = "any";
            SocketBindAllow = singleton "tcp:${toString port}";
            # Allow is checked first, so the frame's subnet gets through.
            IPAddressAllow = fences.loopback ++ singleton cfg.lan.subnet;
            IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          };
        };
      };
    };
}
