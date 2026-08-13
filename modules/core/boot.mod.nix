{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.boot;
  flake.nixosModules.boot =
    { lib, ... }:
    let
      inherit (lib.modules) mkDefault;
    in
    {
      boot.loader.systemd-boot.enable = mkDefault true;
      boot.loader.systemd-boot.configurationLimit = mkDefault 5;
      boot.loader.efi.canTouchEfiVariables = mkDefault true;

      boot.initrd.systemd.enable = mkDefault true;

      # Compressed swap in RAM on every host: memory pressure lands on
      # page compression instead of the OOM killer. Disk swap exists only
      # where it has a job — hibernation (earth), tiny-RAM overflow (air).
      zramSwap.enable = mkDefault true;
    };
}
