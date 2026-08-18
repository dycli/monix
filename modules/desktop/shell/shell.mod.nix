# The Kestrel desktop shell.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.ship-shell;
  flake.nixosModules.ship-shell =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
    in
    {
      environment.systemPackages = singleton pkgs.quickshell;
      hardware.i2c.enable = true;

      systemd.user.tmpfiles.rules = singleton "d %h/.local/state/kestrel 0700 - - -";

      # systemd user units do not inherit the session's XDG_DATA_DIRS.
      systemd.user.services.ship-shell = {
        description = "Kestrel desktop shell";
        path = [
          pkgs.bluez-tools
          pkgs.brightnessctl
          pkgs.cliphist
          pkgs.ddcutil
          pkgs.quickshell
          pkgs.uwsm
          pkgs.wl-clipboard
          pkgs.wtype
          config.home-manager.users.${config.primaryUser}.home.path
        ];
        partOf = singleton "graphical-session.target";
        after = singleton "graphical-session.target";
        wantedBy = singleton "graphical-session.target";

        environment = {
          XDG_DATA_DIRS = "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";
          KESTREL_BROWSER = getExe pkgs.brave;
          KESTREL_EMAIL = getExe pkgs.thunderbird;
          KESTREL_MESSENGER = getExe pkgs.signal-desktop;
          KESTREL_TERMINAL = getExe pkgs.ghostty;
        };

        serviceConfig = {
          ExecStart = "${getExe pkgs.quickshell} -p ${./qml}";
          Restart = "on-failure";
          RestartSec = 1;
        };
      };
    };
}
