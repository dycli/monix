# KDE apps outside Plasma: plugin discovery and theming.
#
# qt.enable adds every profile's Qt plugin dirs to the session env;
# QT_QPA_PLATFORMTHEME=kde (env.mod.nix) then loads plasma-integration,
# which makes every Qt app — KDE or not — read kdeglobals for colors,
# widget style, fonts and icons.
{ self, ... }:
{
  flake.nixosModules.hyprland = self.nixosModules.kde-integration;
  flake.nixosModules.kde-integration = {
    qt.enable = true;
  };

  flake.homeModules.hyprland = self.homeModules.kde-integration;

  flake.homeModules.kde-integration =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.kdePackages.plasma-integration
        pkgs.kdePackages.breeze
      ];

      # KDE apps write back to kdeglobals at runtime, so it cannot be a store
      # symlink; f+ reasserts the declared content at each boot.
      systemd.user.tmpfiles.rules = [
        "f+ %h/.config/kdeglobals 0644 - - - [General]\\nColorScheme=BreezeDark\\n[KDE]\\nwidgetStyle=Breeze\\n[Icons]\\nTheme=breeze-dark\\n"
      ];
    };
}
