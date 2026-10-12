# bridge, the seat's notes: a folder of markdown where the engineer keeps
# plans and the facts that are true now, as hippo keeps what was said.
# It is bind-mounted as `bridge` inside the primary user's Syncthing folder
# (syncthing.mod.nix), so it reaches the captain's devices with no new
# folder to accept; Obsidian opens that subfolder as the vault "bridge".
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.notes;
  flake.nixosModules.notes =
    { config, lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.ship.topology) seat;
    in
    {
      config = mkIf config.services.syncthing.enable {
        # The primary user is already in the seat's group.
        users.users.${config.services.syncthing.user}.extraGroups = singleton seat.user;
        systemd.tmpfiles.rules = singleton "d ${seat.notes} 2770 ${seat.user} ${seat.user} -";

        fileSystems."${config.services.syncthing.settings.folders."zahzi-nepxh".path}/bridge" = {
          device = seat.notes;
          fsType = "none";
          options = [
            "bind"
            "nofail"
          ];
        };
        # Syncthing replaces a file by rename, so the seat's own files need
        # only the shared directory; files Syncthing creates must leave the
        # group write so the seat can edit them in place. The sync folder
        # carries modes, and a phone sends none, so the umask decides.
        systemd.services.syncthing.serviceConfig.UMask = "0002";
      };
    };
}
