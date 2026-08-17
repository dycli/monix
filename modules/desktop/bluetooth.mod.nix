# Bluetooth stack. Kestrel owns the pairing agent while its Bluetooth menu is open.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.bluetooth;
  flake.nixosModules.bluetooth = {
    hardware.bluetooth.enable = true;
  };
}
