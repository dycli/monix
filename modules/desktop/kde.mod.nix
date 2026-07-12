# KDE apps (Dolphin, Ark, …) outside Plasma: plugin discovery and theming.
#
# Two gaps this closes:
#
#  1. Cross-package KDE plugins don't load: Dolphin's "Extract/Compress"
#     context menu is a KFileItemAction plugin shipped by Ark, found via
#     QT_PLUGIN_PATH — which nothing sets outside Plasma. `qt.enable` adds
#     every profile's Qt 5/6 plugin and QML dirs to the session env
#     (platformTheme/style stay unset: qt6ct is already the platform theme
#     via UWSM env, see hyprland.mod.nix, and DMS owns its config).
#
#  2. KDE apps ignore qt6ct palettes: KColorScheme reads
#     ~/.config/kdeglobals instead, which nothing wrote — so Dolphin sat in
#     unthemed light mode. DMS's dynamic theming already generates a matugen
#     KColorScheme at ~/.local/share/color-schemes/DankMatugen.colors (the
#     "kcolorscheme" matugen template, on by default); kdeglobals only needs
#     to name it. The file is seeded by tmpfiles rather than linked from the
#     store because KDE apps write back to it at runtime (file-dialog state,
#     etc.) — same GUI-owned-file pattern as DMS's outputs.lua in
#     hyprland.mod.nix. `w` (write) is not used: `f` leaves an existing
#     file alone.
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
