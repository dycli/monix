# Hyprland session environment variables.
{
  flake.homeModules.hyprland =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      # One `hl.env(key, value)` call per list element.
      mkEnv = key: value: {
        _args = [
          key
          value
        ];
      };
    in
    {
      wayland.windowManager.hyprland.settings.env = [
        (mkEnv "GDK_SCALE" "2")
        # Cursor env comes from DMS's cursor.lua, not static config.
        (mkEnv "GDK_BACKEND" "wayland")
        (mkEnv "QT_QPA_PLATFORM" "wayland")
        # qt6ct-kde so DMS's Qt colours reach Qt apps; the widget
        # style itself is picked in qt6ct.
        (mkEnv "QT_QPA_PLATFORMTHEME" "qt6ct")
        (mkEnv "SDL_VIDEODRIVER" "wayland")
        (mkEnv "MOZ_ENABLE_WAYLAND" "1")
        (mkEnv "ELECTRON_OZONE_PLATFORM_HINT" "wayland")
        (mkEnv "OZONE_PLATFORM" "wayland")
        # Expanded statically: Hyprland's env does no shell expansion,
        # so a literal $VAR would propagate into the session and break
        # nvim's runtimepath expansion under non-POSIX shells.
        (mkEnv "XDG_DATA_DIRS" "/etc/profiles/per-user/${osConfig.primaryUser}/share:/run/current-system/sw/share")
        (mkEnv "EDITOR" (config.desktopApps.editor))
        # For CLI tools that consult BROWSER before falling back to
        # xdg-open (whose scheme-handler pin points here anyway).
        (mkEnv "BROWSER" (lib.getExe config.desktopApps.browser))
        # The theme DMS's generated gtk.css is written against.
        (mkEnv "GTK_THEME" "adw-gtk3-dark")
      ];
    };
}
