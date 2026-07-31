# Pairing UI is DMS's control centre; bluetoothctl covers the rest.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.bluetooth;
  flake.nixosModules.bluetooth = {
    hardware.bluetooth.enable = true;
  };
}
