# Android application container for desktop hosts.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.waydroid;
  flake.nixosModules.waydroid = {
    virtualisation.waydroid.enable = true;
  };
}
