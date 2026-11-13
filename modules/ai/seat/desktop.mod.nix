# The seat's graphical session: a headless sway under the seat's own systemd
# user manager, so what its agents launch (browsers, desktop apps under test)
# gets a real Wayland display, session bus and portals instead of each tool
# starting its own. Sway rather than Hyprland because Hyprland needs a DRM
# seat to start; wlroots runs on its headless backend alone.
#
# The captain watches it over VNC on Water's tailnet address. wayvnc serves
# only a UNIX socket in the seat's runtime directory; a system socket outside
# the seat's slice carries the tailnet side, so the seat's address fence
# stays shut. Tailnet membership is the gate, as for every service here.
_:
let
  # libwayland's first automatic socket name; the session is the only
  # compositor in the seat's runtime directory.
  display = "wayland-1";
  vncSocket = "wayvnc.sock";
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

      systemd.user.services.wayvnc = {
        Unit = {
          Description = "VNC server for the seat's session";
          PartOf = lib.lists.singleton "sway-session.target";
          After = lib.lists.singleton "sway-session.target";
        };
        Service = {
          ExecStartPre = "${lib.meta.getExe' pkgs.coreutils "rm"} -f %t/${vncSocket}";
          ExecStart = "${getExe pkgs.wayvnc} --output=HEADLESS-1 --unix-socket %t/${vncSocket}";
          Restart = "on-failure";
        };
        Install.WantedBy = lib.lists.singleton "sway-session.target";
      };

      home.packages = [
        pkgs.grim
        pkgs.wl-clipboard
        pkgs.wtype
      ];
    };

  flake.nixosModules.seat =
    { lib, pkgs, ... }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship.topology) seat hostTailnetAddr;

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

      systemd.sockets.seat-vnc = {
        description = "VNC to the seat's session, on the tailnet";
        wantedBy = singleton "sockets.target";
        socketConfig = {
          ListenStream = "${hostTailnetAddr}:5900";
          # Binds before tailscaled has brought the address up.
          FreeBind = true;
          IPAddressAllow = lib.ship.fences.tailnet;
          IPAddressDeny = "any";
        };
      };
      systemd.services.seat-vnc = {
        description = "VNC to the seat's session, on the tailnet";
        requires = singleton "seat-vnc.socket";
        after = singleton "seat-vnc.socket";
        serviceConfig = {
          # The seat's own runtime directory is readable only by the seat.
          User = seat.user;
          ExecStart = "${lib.meta.getExe' pkgs.systemd "systemd-socket-proxyd"} /run/user/${toString seat.uid}/${vncSocket}";
          PrivateNetwork = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      };
    };
}
