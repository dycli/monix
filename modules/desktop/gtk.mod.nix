# GTK theming: the Breeze GTK port, for the Breeze widget style the Qt side
# uses (kde-integration.mod.nix). GTK_THEME is set in hyprland's env.mod.nix.
{ self, ... }:
{
  flake.homeModules.desktop = self.homeModules.gtk;
  flake.homeModules.gtk =
    { pkgs, lib, ... }:
    {
      home.packages = lib.lists.singleton pkgs.kdePackages.breeze-gtk;
    };
}
