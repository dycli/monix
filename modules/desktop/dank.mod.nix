# DankMaterialShell: one quickshell-based desktop shell providing the bar,
# notifications, launcher (spotlight), OSD, control center, lock screen with
# idle handling, wallpaper manager, clipboard history, and polkit agent.
# Started from Hyprland via `dms run` (see hyprland.mod.nix).
#
# The shell itself stays on nixpkgs' `programs.dms-shell` module; the
# `dank-material-shell` flake input supplies only the newer dms package.
# The greetd greeter lives in the separate `dank-greeter` flake (nixpkgs
# does not ship a DMS greeter module).
{ inputs, ... }:
{
  flake.nixosModules.dank =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.lists) singleton;
    in
    {
      imports = singleton inputs.dank-greeter.nixosModules.default;

      config = mkIf config.isDesktop {
        programs.dms-shell.enable = true;

        # nixpkgs' dms-shell (1.4.6) predates Hyprland 0.55's Lua-only command
        # socket: it dispatches old-style strings ("workspace 2"), which the
        # socket rejects, so bar workspace clicking/scrolling silently fails.
        # The flake's master build speaks the new API (hl.dsp.focus{...}).
        #
        # The overrideAttrs preloads the spotlight launcher: upstream keeps
        # it in a LazyLoader that only instantiates on first SUPER+D, making
        # that first open visibly slow. Quickshell's `loading: true`
        # instantiates it asynchronously at startup without showing it.
        # --replace-fail breaks the build loudly if upstream renames the
        # loader.
        programs.dms-shell.package =
          (inputs.dank-material-shell.packages.${pkgs.stdenv.hostPlatform.system}.dms-shell.overrideAttrs
            (old: {
              postInstall = (old.postInstall or "") + ''
                substituteInPlace $out/share/quickshell/dms/DMSShell.qml \
                  --replace-fail "id: dankLauncherV2ModalLoader" "id: dankLauncherV2ModalLoader; loading: true"
              '';
            })
          );

        # Wallpaper-synced app theming (Settings -> Theme & Colors -> "Apply
        # GTK/Qt Themes"). enableDynamicTheming provides matugen; adw-gtk3 is
        # the GTK theme DMS's generated gtk.css targets; qt5ct covers
        # remaining Qt5 apps.
        #
        # Qt6 theming has two halves. KDE apps (Dolphin, Ark) ignore qt6ct
        # palettes entirely and follow ~/.config/kdeglobals -> DMS's matugen
        # KColorScheme instead — wired in kde.mod.nix. Non-KDE Qt6 apps read
        # the qt6ct palette, but nixpkgs' kdePackages.qt6ct is built without
        # the fork's KColorScheme support (nixpkgs issue #489021), so DMS's
        # "Apply Qt Themes" does nothing for them. GTK theming is unaffected.
        # DMS owns the generated files at runtime (gtk.css, qt5ct/qt6ct
        # configs, color schemes) — home-manager must not manage those paths.
        programs.dms-shell.enableDynamicTheming = true;
        environment.systemPackages = [
          pkgs.adw-gtk3
          pkgs.kdePackages.qt6ct
          pkgs.libsForQt5.qt5ct
        ];

        programs.dms-greeter = {
          enable = true;
          compositor.name = "hyprland";

          # Mirror the user's DMS state into the greeter: greetd's preStart
          # copies settings.json / session.json / dms-colors.json (and the
          # wallpaper files they reference) from this home into the greeter
          # cache at every greetd start, so greeter theming follows whatever
          # the session last used.
          configHome = "/home/${config.primaryUser}";

          # dms-greeter's default Hyprland config disables the logo but not
          # the splash text/quote, so it still flashes before the greeter UI
          # renders. customConfig REPLACES that default entirely (the
          # greeter script only appends its own exec-once line after it), so
          # we reproduce the default here and add disable_splash_rendering.
          compositor.customConfig = ''
            env = DMS_RUN_GREETER,1

            misc {
                disable_hyprland_logo = true
                disable_splash_rendering = true
            }
          '';
        };

        # Quickshell's battery service reads UPower; without the daemon the
        # DMS bar always shows AC power.
        services.upower.enable = true;

        # systemd user units don't inherit the session's XDG_DATA_DIRS on
        # NixOS; without it the DMS launcher finds no .desktop entries.
        systemd.user.services.dms.environment.XDG_DATA_DIRS =
          "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";

        # DMS's theming tab errors with "Missing Environment Variables" unless
        # the shell process itself sees the Qt platform theme it manages.
        systemd.user.services.dms.environment.QT_QPA_PLATFORMTHEME = "qt6ct";
      };
    };
}
