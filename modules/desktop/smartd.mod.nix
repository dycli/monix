# SMART attribute monitoring for the desktops' drives: prefail warnings
# land in the journal and on the session via wall. water wires its own
# smartd into the Matrix alert plane (alerts.mod.nix); the desktops have
# no alert credentials, so local warning is the ceiling here. No
# scheduled self-tests — they fight sleep and battery; attribute
# tracking is where the warning value is.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.smartd;
  flake.nixosModules.smartd = {
    services.smartd.enable = true;
  };
}
