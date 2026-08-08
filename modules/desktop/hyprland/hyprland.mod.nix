# The Hyprland desktop concern: compositor + session at the system
# level, the session core at the home level. The home configuration is
# split across this folder — each sibling file merges into
# flake.homeModules.hyprland:
#   appearance.mod.nix — borders, blur, layout, window/layer rules
#   input.mod.nix      — keyboard, touchpad, gestures
#   keybinds.mod.nix   — every hl.bind
#   plugins.mod.nix    — gloview + hyprbars and their guarded config
{
  flake.nixosModules.hyprland =
    { lib, pkgs, ... }:
    {
      programs.hyprland.enable = true;

      # UWSM owns the systemd session lifecycle. In this nixpkgs pin
      # withUWSM only flips programs.uwsm.enable; it neither registers
      # Hyprland with UWSM nor adds a session entry.
      programs.hyprland.withUWSM = true;

      # nixpkgs' waylandCompositors entry cannot pass -D before --, so
      # uwsm seeds XDG_CURRENT_DESKTOP from the binary name and its quirk
      # plugin appends rather than replaces, yielding
      # "start-hyprland:Hyprland". Hyprland matches that exactly against
      # "Hyprland" and otherwise warns about external management every
      # session. Writing the session entry here passes -D Hyprland up
      # front; mkForce replaces the plain entry rather than adding to it,
      # so the greeter offers one Hyprland session.
      services.displayManager.sessionPackages = lib.mkForce [
        (pkgs.writeTextFile {
          name = "hyprland-uwsm";
          text = ''
            [Desktop Entry]
            Name=Hyprland
            Comment=Hyprland compositor managed by UWSM
            Exec=${lib.getExe pkgs.uwsm} start -F -D Hyprland -- ${lib.getExe' pkgs.hyprland "start-hyprland"}
            Type=Application
          '';
          # Must launch start-hyprland rather than the raw binary: the
          # "started without start-hyprland" warning clears only with a
          # valid --watchdog-fd, a pipe start-hyprland creates when it
          # forks. It does no systemd manipulation itself, so nesting it
          # inside the uwsm-managed unit is safe.
          destination = "/share/wayland-sessions/hyprland-uwsm.desktop";
          derivationArgs = {
            # Mirrors nixpkgs' mk_uwsm_desktop_entry passthru so
            # sessionPackages can find the session id.
            passthru.providedSessions = [ "hyprland-uwsm" ];
          };
        })
      ];

      hardware.graphics.enable = true;

      xdg.portal.enable = true;
      xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

      # Without flatpak installed its document portal fails at session
      # start and degrades the user service manager; the hyprland and gtk
      # portals do not depend on it.
      systemd.user.units."xdg-document-portal.service".enable = false;

      # greetd and the session launch command are configured by the
      # greeter module in dank.mod.nix.

      # Secret storage for desktop applications, unlocked at greetd login.
      services.gnome.gnome-keyring.enable = true;
      security.pam.services.greetd.enableGnomeKeyring = true;
    };

  # configType is pinned to "lua" because home-manager otherwise infers it
  # from home.stateVersion, so a future bump could silently switch config
  # generation.
  flake.homeModules.hyprland =
    {
      config,
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.generators) mkLuaInline;
      inherit (lib.modules) mkOrder;
      inherit (lib.meta) getExe getExe';

      # One `hl.env(key, value)` call per list element.
      mkEnv = key: value: {
        _args = [
          key
          value
        ];
      };
    in
    {
      # DMS writes the monitor layout here at runtime, so it must be a
      # real user-writable file rather than a store symlink; `f` seeds it
      # without touching an existing one.
      systemd.user.tmpfiles.rules = [
        "f %h/.config/hypr/dms/outputs.lua 0644 - - -"
        # Cursor theme and size are DMS-owned the same way.
        "f %h/.config/hypr/dms/cursor.lua 0644 - - -"
      ];

      wayland.windowManager.hyprland = {
        enable = true;
        configType = "lua";

        # The NixOS-level programs.hyprland.enable installs these
        # system-wide; null avoids a second home-manager copy.
        package = null;
        portalPackage = null;

        # UWSM brings up the graphical-session targets itself, so this
        # module's own hook would race it; `uwsm finalize` in the first
        # autostart line exports the session environment instead.
        systemd.enable = false;

        # pcall rather than a bare require: if the seed file is missing,
        # a first login racing tmpfiles would otherwise abort the whole
        # Lua config and take the session down. mkOrder 900 keeps the
        # requires ahead of the plugin blocks (plugins.mod.nix, default
        # order) and any host-level mkAfter additions.
        extraConfig = mkOrder 900 ''
          pcall(require, "dms.outputs")
          pcall(require, "dms.cursor")
        '';

        settings = {
          env = [
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
            # The theme DMS's generated gtk.css is written against.
            (mkEnv "GTK_THEME" "adw-gtk3-dark")
          ];

          # `uwsm finalize` must run first: it exports the session
          # variables and signals wayland-wm@Hyprland ready, unblocking
          # graphical-session.target. Long-running autostarts are wrapped
          # in `uwsm app --` to get their own scopes; one-shot keybind
          # execs are not.
          on = {
            _args = [
              "hyprland.start"
              (mkLuaInline ''
                function()
                  hl.exec_cmd("${getExe pkgs.uwsm} finalize XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_ID")
                  hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe pkgs.wl-clip-persist} --clipboard regular")
                  hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe' pkgs.wl-clipboard "wl-paste"} --watch ${getExe pkgs.cliphist} store")
                end
              '')
            ];
          };
        };
      };
    };
}
