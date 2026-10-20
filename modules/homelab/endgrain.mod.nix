# Endgrain's staff schedule at https://endgrain.<domain> (tailnet only for
# now): ./endgrain lays out each week's shifts, posts them, and takes
# time-off requests. Each person's page lives under /s/<token>, so letting
# staff in from the internet later means a tunnel that admits /s/ alone,
# the way Immich shares photos.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.endgrain;
  flake.nixosModules.endgrain =
    { lib, pkgs, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.ship) fences;

      port = 8980;
      endgrain = lib.ship.rustTool pkgs { src = ./endgrain; };
    in
    {
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
          # It talks to nobody; only nginx reaches it, over loopback.
          IPAddressAllow = fences.loopback;
          IPAddressDeny = "any";
        };
      };
    };
}
