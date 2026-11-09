# The seat's graphical session: a headless sway under the seat's own systemd
# user manager, so what its agents launch (browsers, desktop apps under test)
# gets a real Wayland display, session bus and portals instead of each tool
# starting its own. Sway rather than Hyprland because Hyprland needs a DRM
# seat to start; wlroots runs on its headless backend alone.
_:
let
  # libwayland's first automatic socket name; the session is the only
  # compositor in the seat's runtime directory.
  display = "wayland-1";
in
{
  flake.homeModules.cockpit =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.meta) getExe;
    in
    {
      wayland.windowManager.sway = {
        enable = true;
        # Starts sway-session.target with the display in the user manager's
        # environment once the compositor is up.
        systemd.enable = true;
        config = {
          output.HEADLESS-1.resolution = "1920x1080";
          bars = [ ];
        };
      };

      systemd.user.services.sway = {
        Unit.Description = "The seat's headless Wayland session";
        Service = {
          ExecStart = getExe config.wayland.windowManager.sway.package;
          # Drawn on the GPU: under wlroots' software renderer a Vulkan
          # client such as vkcube crashes on its first frame.
          Environment = [
            "WLR_BACKENDS=headless"
            "WLR_LIBINPUT_NO_DEVICES=1"
            "WLR_RENDERER=gles2"
            "WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128"
          ];
          Restart = "on-failure";
        };
        Install.WantedBy = lib.lists.singleton "default.target";
      };

      home.packages = [
        pkgs.grim
        pkgs.wl-clipboard
        pkgs.wtype
      ];
    };

  flake.nixosModules.seat =
    { lib, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship.topology) seat;

      runtime = "/run/user/${toString seat.uid}";
      # The seat's system services join the session rather than run beside it.
      session = {
        wants = singleton "user@${toString seat.uid}.service";
        after = singleton "user@${toString seat.uid}.service";
        environment = {
          XDG_RUNTIME_DIR = runtime;
          WAYLAND_DISPLAY = display;
          DBUS_SESSION_BUS_ADDRESS = "unix:path=${runtime}/bus";
        };
      };
    in
    {
      # The user manager, and with it the session, runs from boot.
      users.users.${seat.user}.linger = true;

      systemd.services.libri = session;
      systemd.services.tern-remote = session;
      systemd.services.paseo = session;
    };
}
