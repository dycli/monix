# Transitional DMS bottom testing bar.
{ self, inputs, ... }:
{
  flake.nixosModules.hyprland = self.nixosModules.dank;
  flake.nixosModules.dank =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      programs.dms-shell.enable = true;

      # DMS remains for shell surfaces Kestrel has not replaced. These small
      # switches prevent it from competing with native Hyprland services.
      programs.dms-shell.package =
        inputs.dank-material-shell.packages.${pkgs.stdenv.hostPlatform.system}.dms-shell.overrideAttrs
          (old: {
            postInstall = (old.postInstall or "") + ''
              substituteInPlace $out/share/quickshell/dms/DMSShell.qml \
                --replace-fail "active: root.osdSurfacesLoaded" 'active: root.osdSurfacesLoaded && Quickshell.env("DMS_DISABLE_OSD") !== "1"'
              substituteInPlace $out/share/quickshell/dms/Services/IdleService.qml \
                --replace-fail "property bool enabled: true" 'property bool enabled: Quickshell.env("DMS_DISABLE_IDLE") !== "1"'
              substituteInPlace $out/share/quickshell/dms/shell.qml \
                --replace-fail "id: wallpaperLoader" 'id: wallpaperLoader; active: Quickshell.env("DMS_DISABLE_WALLPAPER") !== "1"'
              substituteInPlace $out/share/quickshell/dms/Modules/Lock/Lock.qml \
                --replace-fail "id: root" 'id: root; readonly property string externalLocker: Quickshell.env("DMS_EXTERNAL_LOCKER")' \
                --replace-fail "SettingsData.customPowerActionLock" "root.externalLocker" \
                --replace-fail "function handleLoginctlCustomLock(): bool {" 'function handleLoginctlCustomLock(): bool { if (Quickshell.env("DMS_DISABLE_LOCK_LISTENER") === "1") return true;'
            '';
          });

      # Qt and GTK theming are owned by kde-integration and gtk; DMS renders
      # only its own shell UI, so its dynamic theming stays off.
      programs.dms-shell.enableDynamicTheming = false;

      # LUKS already gates boot; the greeter only appears after a logout.
      services.displayManager.autoLogin = {
        enable = true;
        user = config.primaryUser;
      };

      services.greetd = {
        enable = true;
        settings.default_session = {
          command = "${lib.meta.getExe pkgs.tuigreet} --time --remember --remember-session --sessions ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
          user = "greeter";
        };
      };

      # Quickshell's battery service reads UPower.
      services.upower.enable = true;

      # systemd user units do not inherit the session's XDG_DATA_DIRS.
      systemd.user.services.dms.environment = {
        XDG_DATA_DIRS = "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";
        DMS_DISABLE_IDLE = "1";
        DMS_DISABLE_LOCK_LISTENER = "1";
        DMS_DISABLE_OSD = "1";
        DMS_DISABLE_POLKIT = "1";
        DMS_DISABLE_WALLPAPER = "1";
        DMS_EXTERNAL_LOCKER = lib.meta.getExe pkgs.hyprlock;
      };

    };
}
