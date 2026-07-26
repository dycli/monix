# KDE apps (Dolphin, Ark, …) outside Plasma: plugin discovery and theming.
#
# 1. Cross-package KDE plugins don't load: Dolphin's "Extract/Compress"
#    context menu is a KFileItemAction plugin shipped by Ark, found via
#    QT_PLUGIN_PATH — which nothing sets outside Plasma. `qt.enable` adds
#    every profile's Qt 5/6 plugin and QML dirs to the session env.
#
# 2. KDE apps ignore qt6ct palettes: KColorScheme reads ~/.config/kdeglobals
#    instead, which nothing wrote — so Dolphin sat in unthemed light mode.
#    DMS already generates a matugen KColorScheme; kdeglobals only needs to
#    name it. Seeded by tmpfiles (`f`, not `w`) since KDE apps write back to
#    the file at runtime (file-dialog state, etc.).
{
  flake.nixosModules.kde-integration =
    { config, lib, ... }:
    {
      config = lib.modules.mkIf config.isDesktop {
        qt.enable = true;
      };
    };

  flake.homeModules.kde-integration =
    { lib, osConfig, ... }:
    {
      config = lib.modules.mkIf osConfig.isDesktop {
        systemd.user.tmpfiles.rules = [
          "f %h/.config/kdeglobals 0644 - - - [General]\\nColorScheme=DankMatugen\\n[Icons]\\nTheme=breeze-dark\\n"
        ];
      };
    };
}
