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
        (mkEnv "GDK_BACKEND" "wayland")
        (mkEnv "QT_QPA_PLATFORM" "wayland")
        # Loads plasma-integration: every Qt app reads kdeglobals
        # (kde-integration.mod.nix).
        (mkEnv "QT_QPA_PLATFORMTHEME" "kde")
        (mkEnv "SDL_VIDEODRIVER" "wayland")
        (mkEnv "MOZ_ENABLE_WAYLAND" "1")
        (mkEnv "ELECTRON_OZONE_PLATFORM_HINT" "wayland")
        (mkEnv "OZONE_PLATFORM" "wayland")
        # Expanded statically: Hyprland's env does no shell expansion, so a
        # literal $VAR would propagate into the session.
        (mkEnv "XDG_DATA_DIRS" "/etc/profiles/per-user/${osConfig.primaryUser}/share:/run/current-system/sw/share")
        (mkEnv "EDITOR" (config.desktopApps.editor))
        (mkEnv "BROWSER" (lib.getExe config.desktopApps.browser))
        # Matches the Qt side's BreezeDark kdeglobals scheme.
        (mkEnv "GTK_THEME" "Breeze-Dark")
        # HYPRCURSOR_* for the compositor, XCURSOR_* for clients.
        (mkEnv "XCURSOR_THEME" "Bibata-Modern-Amber")
        (mkEnv "XCURSOR_SIZE" "24")
        (mkEnv "HYPRCURSOR_THEME" "Bibata-Modern-Amber")
        (mkEnv "HYPRCURSOR_SIZE" "24")
      ];
    };
}
