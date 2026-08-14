# SMART attribute monitoring for the desktops' drives: prefail warnings
# land in the journal and on the session via wall. water wires its own
# smartd into the Matrix alert plane (alerts.mod.nix); the desktops have
# no alert credentials, so local warning is the ceiling here. No
# scheduled self-tests — they fight sleep and battery; attribute
# tracking is where the warning value is.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.smartd;
  flake.nixosModules.smartd =
    { lib, ... }:
    {
      services.smartd.enable = true;

      # Under Type=notify smartd signals readiness only after probing every
      # disk, and multi-user.target — hence the greeter — waits for it, so
      # one slow probe becomes a blank screen at boot. Nothing orders after
      # smartd; start it simple and let the scan run in the background.
      systemd.services.smartd.serviceConfig.Type = lib.modules.mkForce "simple";
    };
}
