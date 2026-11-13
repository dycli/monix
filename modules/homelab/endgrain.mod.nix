# Endgrain's staff schedule at https://endgrain.<domain>: ./endgrain lays
# out each week's shifts, posts them, and takes staff requests. The tailnet
# reaches it through the shared proxy, staff through a Cloudflare Tunnel.
# The app asks for a password itself (staff or manager) on every path, so
# the tunnel passes everything through.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.endgrain;
  flake.nixosModules.endgrain =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.options) mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      port = 8980;
      endgrain = lib.ship.rustTool pkgs { src = ./endgrain; };
      tokenFile = config.endgrain.tunnelTokenFile;
    in
    {
      options.endgrain.tunnelTokenFile = mkOption {
        type = types.str;
        description = ''
          Cloudflare Tunnel connector token for the staff door. The
          hostname -> http://127.0.0.1:${toString port}
          mapping is dashboard-side.
        '';
      };

      config = {
        shipProxy.routes.endgrain.port = port;

        users.users.endgrain = {
          isSystemUser = true;
          group = "endgrain";
        };
        users.groups.endgrain = { };

        systemd.services.endgrain = {
          description = "Endgrain's staff schedule";
          wantedBy = singleton "multi-user.target";
          environment = {
            ENDGRAIN_LISTEN = "127.0.0.1:${toString port}";
            ENDGRAIN_STATE = "%S/endgrain";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            User = "endgrain";
            Group = "endgrain";
            StateDirectory = "endgrain";
            ExecStart = getExe endgrain;
            Restart = "on-failure";
            SocketBindDeny = "any";
            SocketBindAllow = singleton "tcp:${toString port}";
            # It talks to nobody; nginx and the tunnel reach it over loopback.
            IPAddressAllow = fences.loopback;
            IPAddressDeny = "any";
          };
        };

        systemd.services.endgrain-tunnel = lib.ship.tunnel pkgs {
          description = "Cloudflare Tunnel for Endgrain's staff";
          tokenFile = tokenFile;
          backend = "endgrain.service";
        };
      };
    };
}
