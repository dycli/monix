# The vault: a folder of markdown where the engineer keeps plans and the
# facts that are true now, as hippo keeps what was said. Syncthing carries
# it to the captain's devices (syncthing.mod.nix), where Obsidian opens it.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.vault;
  flake.nixosModules.vault =
    { config, lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.ship.topology) seat;
    in
    {
      config = mkIf config.services.syncthing.enable {
        users.groups.vault = { };
        users.users.${seat.user}.extraGroups = singleton "vault";
        users.users.${config.services.syncthing.user}.extraGroups = singleton "vault";
        systemd.tmpfiles.rules = singleton "d ${seat.vault} 2770 ${seat.user} vault -";

        services.syncthing.settings.folders.vault = {
          path = seat.vault;
          # Modes come from the umask, not from the device that last wrote.
          ignorePerms = true;
        };
        # Syncthing replaces a file by rename, so the seat's own files need
        # only the shared directory; files Syncthing creates must leave the
        # group write so the seat can edit them in place.
        systemd.services.syncthing.serviceConfig.UMask = "0002";
      };
    };
}
