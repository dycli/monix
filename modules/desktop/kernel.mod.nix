# Desktops run the Zen kernel for interactive responsiveness.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.kernel;
  flake.nixosModules.kernel =
    { pkgs, ... }:
    {
      boot.kernelPackages = pkgs.linuxPackages_zen;
    };
}
