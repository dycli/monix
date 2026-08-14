# Hyprland compositor and session at the system level, session core at the home
# level. Sibling files in this folder merge into flake.homeModules.hyprland.
{
  flake.nixosModules.hyprland =
    { lib, pkgs, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkForce;
      inherit (lib.meta) getExe getExe';
    in
    {
      programs.hyprland.enable = true;

      # In this nixpkgs pin withUWSM only flips programs.uwsm.enable; it
      # neither registers Hyprland with UWSM nor adds a session entry.
      programs.hyprland.withUWSM = true;

      # nixpkgs' waylandCompositors entry cannot pass -D before --, so uwsm
      # derives XDG_CURRENT_DESKTOP from the binary name and Hyprland's exact
      # match fails, warning about external management every session.
      services.displayManager.sessionPackages = mkForce (
        singleton (
          pkgs.writeTextFile {
            name = "hyprland-uwsm";
            text = ''
              [Desktop Entry]
              Name=Hyprland
              Comment=Hyprland compositor managed by UWSM
              Exec=${getExe pkgs.uwsm} start -F -D Hyprland -- ${getExe' pkgs.hyprland "start-hyprland"}
              Type=Application
            '';
            # start-hyprland forks to create the --watchdog-fd pipe the raw
            # binary lacks, and does no systemd manipulation of its own.
            destination = "/share/wayland-sessions/hyprland-uwsm.desktop";
            derivationArgs = {
              # sessionPackages reads the session id from this passthru.
              passthru.providedSessions = singleton "hyprland-uwsm";
            };
          }
        )
      );

      hardware.graphics.enable = true;

      xdg.portal.enable = true;
      xdg.portal.extraPortals = singleton pkgs.xdg-desktop-portal-gtk;

      # Without flatpak installed this portal fails at session start and
      # degrades the user service manager; no portal in use depends on it.
      systemd.user.units."xdg-document-portal.service".enable = false;

      services.gnome.gnome-keyring.enable = true;
      security.pam.services.greetd.enableGnomeKeyring = true;
    };

  flake.homeModules.hyprland =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.generators) mkLuaInline;
      inherit (lib.modules) mkOrder;
      inherit (lib.meta) getExe getExe';
    in
    {
      # DMS rewrites this at runtime, so it must be a real user-writable
      # file rather than a store symlink; `f` seeds without overwriting.
      systemd.user.tmpfiles.rules = [
        "f %h/.config/hypr/dms/outputs.lua 0644 - - -"
        # A blank-password default keyring: autologin types no password, so
        # PAM cannot unlock a protected one. Plaintext-format contents stay
        # under LUKS. Seeded only if missing — the daemon writes secrets
        # into these files.
        "f %h/.local/share/keyrings/default 0600 - - - Default_keyring\\n"
        "f %h/.local/share/keyrings/Default_keyring.keyring 0600 - - - [keyring]\\ndisplay-name=Default keyring\\nctime=1\\nmtime=1\\nlock-on-idle=false\\nlock-after=false\\n"
      ];

      wayland.windowManager.hyprland = {
        enable = true;

        # Pinned rather than inferred from home.stateVersion, which a future
        # bump would silently change.
        configType = "lua";

        package = null;
        portalPackage = null;

        # UWSM brings up the graphical-session targets itself.
        systemd.enable = false;

        # pcall, not require: a first login racing tmpfiles would otherwise
        # abort the whole Lua config. mkOrder 900 keeps the requires ahead of
        # the default-order plugin blocks and host-level mkAfter additions.
        extraConfig = mkOrder 900 ''
          pcall(require, "dms.outputs")
        '';

        settings = {
          # `uwsm finalize` must run first: it exports the session variables
          # and unblocks graphical-session.target. Cursor and toolkit-theme
          # vars are listed because systemd-launched services spawn apps from
          # the user-manager environment, not the session env; XDG_DATA_DIRS
          # for the same reason — without the profile share dirs, desktop-id
          # resolution (xdg-open, KService) finds no applications. Long-running
          # autostarts are wrapped in `uwsm app --` to get their own scopes.
          on = {
            _args = [
              "hyprland.start"
              (mkLuaInline ''
                function()
                  hl.exec_cmd("${getExe pkgs.uwsm} finalize XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_ID XDG_DATA_DIRS XCURSOR_THEME XCURSOR_SIZE HYPRCURSOR_THEME HYPRCURSOR_SIZE QT_QPA_PLATFORMTHEME GTK_THEME")
                  hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe pkgs.wl-clip-persist} --clipboard regular")
                  hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe' pkgs.wl-clipboard "wl-paste"} --watch ${getExe pkgs.cliphist} store")
                  -- Idles in the tray so the browser extension can raise the
                  -- unlock dialog on demand instead of a manual app launch.
                  hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe config.desktopApps.passwordManager.package} --minimized")
                end
              '')
            ];
          };
        };
      };
    };
}
