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

      # Wallpaper-synced app theming. adw-gtk3 is the theme DMS's generated
      # gtk.css targets; it owns those files at runtime, so home-manager must
      # not manage the paths. nixpkgs' kdePackages.qt6ct lacks the fork's
      # KColorScheme support (nixpkgs #489021), so Qt theming is inert.
      programs.dms-shell.enableDynamicTheming = true;
      environment.systemPackages = [
        pkgs.adw-gtk3
        pkgs.kdePackages.qt6ct
        pkgs.libsForQt5.qt5ct
      ];

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

      # The theming tab errors with "Missing Environment Variables" unless the
      # shell process sees the Qt platform theme it manages.
      systemd.user.services.dms.environment.QT_QPA_PLATFORMTHEME = "qt6ct";
    };
}
