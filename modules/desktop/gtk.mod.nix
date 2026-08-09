# GTK theming: the Breeze GTK port, matching the Qt side's BreezeDark
# scheme. GTK_THEME is set in hyprland's env.mod.nix.
{ self, ... }:
{
  flake.homeModules.desktop = self.homeModules.gtk;
  flake.homeModules.gtk =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.kdePackages.breeze-gtk ];
    };
}
