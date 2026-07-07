# Bluetooth on desktops. Pairing/connect UI is DankMaterialShell's control
# center (see dank.mod.nix); use `bluetoothctl` for anything it doesn't
# cover.
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
