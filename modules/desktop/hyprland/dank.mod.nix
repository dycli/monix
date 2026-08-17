# Transitional desktop shell surfaces: launcher, power menu, keybind overlay,
# clipboard history and the bottom testing bar.
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
    let
      inherit (lib.lists) singleton;
    in
    {
      imports = singleton inputs.dank-greeter.nixosModules.default;

      programs.dms-shell.enable = true;

      # DMS remains for shell surfaces Kestrel has not replaced. These small
      # switches prevent it from competing with native Hyprland services.
      programs.dms-shell.package =
        inputs.dank-material-shell.packages.${pkgs.stdenv.hostPlatform.system}.dms-shell.overrideAttrs
          (old: {
            postInstall = (old.postInstall or "") + ''
              substituteInPlace $out/share/quickshell/dms/DMSShell.qml \
                --replace-fail "id: dankLauncherV2ModalLoader" "id: dankLauncherV2ModalLoader; loading: true"
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

      programs.dms-greeter = {
        enable = true;
        compositor.name = "hyprland";

        # greetd's preStart copies this home's DMS settings and referenced
        # wallpapers into the greeter cache on every start.
        configHome = "/home/${config.primaryUser}";

        # customConfig replaces the greeter's default config entirely, so that
        # default is reproduced here with disable_splash_rendering added.
        compositor.customConfig = ''
          env = DMS_RUN_GREETER,1

          misc {
              disable_hyprland_logo = true
              disable_splash_rendering = true
          }
        '';
      };

      # Quickshell's battery service reads UPower.
      services.upower.enable = true;

      # systemd user units do not inherit the session's XDG_DATA_DIRS, and the
      # launcher then finds no .desktop entries.
      systemd.user.services.dms.environment = {
        XDG_DATA_DIRS = "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";
        DMS_DISABLE_IDLE = "1";
        DMS_DISABLE_LOCK_LISTENER = "1";
        DMS_DISABLE_POLKIT = "1";
        DMS_DISABLE_WALLPAPER = "1";
        DMS_EXTERNAL_LOCKER = lib.meta.getExe pkgs.hyprlock;
      };

    };
}
