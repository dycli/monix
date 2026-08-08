# KDE apps (Dolphin, Ark, …) outside Plasma: plugin discovery and theming.
#
# Cross-package KDE plugins are found via QT_PLUGIN_PATH, which nothing sets
# outside Plasma; qt.enable adds every profile's Qt plugin and QML dirs to the
# session env. KDE apps also ignore qt6ct palettes, reading the KColorScheme
# named in kdeglobals instead — seeded with tmpfiles `f` rather than `w`
# because KDE apps write back to that file at runtime.
{ self, ... }:
{
  flake.nixosModules.hyprland = self.nixosModules.kde-integration;
  flake.nixosModules.kde-integration = {
    qt.enable = true;
  };

  flake.homeModules.hyprland = self.homeModules.kde-integration;

  flake.homeModules.kde-integration = {
    systemd.user.tmpfiles.rules = [
      "f %h/.config/kdeglobals 0644 - - - [General]\\nColorScheme=DankMatugen\\n[Icons]\\nTheme=breeze-dark\\n"
    ];
  };
}
