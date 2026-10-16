# The wall frame's homepage at https://frame.<domain>: one Immich album as
# a slideshow with the time over it, served by ./frame. The frame (a rooted
# Frameo on the LAN) cannot join the tailnet, so the server also listens on
# the LAN port directly; the page carries photos only, never the Immich key.
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
      inherit (lib.lists) singleton;
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
          };
          serviceConfig = lib.ship.hardened.tenant // {
            DynamicUser = true;
            ExecStart = getExe frame;
            LoadCredential = singleton "immich-key:${cfg.immichKeyFile}";
            Restart = "on-failure";
            SocketBindDeny = "any";
            SocketBindAllow = singleton "tcp:${toString port}";
            # Immich on loopback, the frame on the LAN; nothing else.
            IPAddressAllow = fences.loopback ++ singleton cfg.lan.subnet;
            IPAddressDeny = "any";
          };
        };
      };
    };
}
