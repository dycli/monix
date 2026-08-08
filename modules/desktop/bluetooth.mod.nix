# Bluetooth stack. Pairing UI comes from the DMS control centre.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.bluetooth;
  flake.nixosModules.bluetooth = {
    hardware.bluetooth.enable = true;
  };
}
