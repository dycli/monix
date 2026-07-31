# A quickshell-based desktop shell: bar, notifications, launcher, OSD,
# control centre, lock screen, wallpaper manager, clipboard history and
# polkit agent, started by its `dms` user unit under UWSM.
#
# The module comes from nixpkgs; the dank-material-shell input supplies
# only a newer package, and the greeter is its own flake.
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

      config = {
        programs.dms-shell.enable = true;

        # nixpkgs' dms-shell 1.4.6 predates Hyprland 0.55's Lua-only
        # command socket and dispatches old-style strings, which the socket
        # rejects, so workspace clicking silently fails.
        #
        # The overrideAttrs preloads the spotlight launcher, which upstream
        # keeps in a LazyLoader that only instantiates on first use.
        # --replace-fail fails the build if upstream renames the loader.
        programs.dms-shell.package = (
          inputs.dank-material-shell.packages.${pkgs.stdenv.hostPlatform.system}.dms-shell.overrideAttrs
            (old: {
              postInstall = (old.postInstall or "") + ''
                substituteInPlace $out/share/quickshell/dms/DMSShell.qml \
                  --replace-fail "id: dankLauncherV2ModalLoader" "id: dankLauncherV2ModalLoader; loading: true"
              '';
            })
        );

        # Wallpaper-synced app theming. enableDynamicTheming provides
        # matugen; adw-gtk3 is the theme DMS's generated gtk.css targets.
        #
        # KDE apps ignore qt6ct palettes and follow kdeglobals instead,
        # wired in kde.mod.nix. Non-KDE Qt6 apps read qt6ct, but nixpkgs'
        # kdePackages.qt6ct lacks the fork's KColorScheme support (nixpkgs
        # #489021), so Qt theming does nothing for them.
        #
        # DMS owns the generated files at runtime, so home-manager must not
        # manage those paths.
        programs.dms-shell.enableDynamicTheming = true;
        environment.systemPackages = [
          pkgs.adw-gtk3
          pkgs.kdePackages.qt6ct
          pkgs.libsForQt5.qt5ct
        ];

        programs.dms-greeter = {
          enable = true;
          compositor.name = "hyprland";

          # greetd's preStart copies this home's DMS settings and the
          # wallpapers they reference into the greeter cache on every start,
          # so greeter theming follows the last session.
          configHome = "/home/${config.primaryUser}";

          # The greeter's default Hyprland config disables the logo but not
          # the splash text, which still flashes before the UI renders.
          # customConfig replaces that default entirely, so it is
          # reproduced here with disable_splash_rendering added.
          compositor.customConfig = ''
            env = DMS_RUN_GREETER,1

            misc {
                disable_hyprland_logo = true
                disable_splash_rendering = true
            }
          '';
        };

        # Quickshell's battery service reads UPower; without it the bar
        # always shows AC power.
        services.upower.enable = true;

        # systemd user units do not inherit the session's XDG_DATA_DIRS on
        # NixOS, and the launcher then finds no .desktop entries.
        systemd.user.services.dms.environment.XDG_DATA_DIRS =
          "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";

        # The theming tab errors with "Missing Environment Variables"
        # unless the shell process sees the Qt platform theme it manages.
        systemd.user.services.dms.environment.QT_QPA_PLATFORMTHEME = "qt6ct";
      };
    };
}
