# SMART attribute monitoring for the desktops' drives: prefail warnings
# land in the journal and on the session via wall. The Matrix alert plane
# exists only on water (alerts.mod.nix), whose smartd config supersedes
# this in the lab bundle. No scheduled self-tests — they fight sleep and
# battery; attribute tracking is where the warning value is.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.smartd;
  flake.nixosModules.smartd = {
    services.smartd.enable = true;
  };
}
