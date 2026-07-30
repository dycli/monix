# Pairing UI is DMS's control centre; bluetoothctl covers the rest.
{
  flake.nixosModules.bluetooth =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf config.isDesktop {
        hardware.bluetooth.enable = true;
      };
    };
}
