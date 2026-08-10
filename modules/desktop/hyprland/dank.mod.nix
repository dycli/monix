# A quickshell-based desktop shell: bar, notifications, launcher, OSD, control
# centre, lock screen, wallpaper, clipboard history and polkit agent.
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

      # nixpkgs' dms-shell 1.4.6 dispatches old-style strings that Hyprland
      # 0.55's Lua-only command socket rejects. The overrideAttrs preloads the
      # spotlight launcher out of upstream's LazyLoader.
      programs.dms-shell.package =
        inputs.dank-material-shell.packages.${pkgs.stdenv.hostPlatform.system}.dms-shell.overrideAttrs
          (old: {
            postInstall = (old.postInstall or "") + ''
              substituteInPlace $out/share/quickshell/dms/DMSShell.qml \
                --replace-fail "id: dankLauncherV2ModalLoader" "id: dankLauncherV2ModalLoader; loading: true"
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
      systemd.user.services.dms.environment.XDG_DATA_DIRS =
        "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";

    };
}
