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

      systemd.sleep.settings.Sleep = lib.modules.mkIf (!config.kestrel.allowSleep) {
        AllowSuspend = false;
        AllowHibernation = false;
        AllowSuspendThenHibernate = false;
        AllowHybridSleep = false;
      };

      systemd.user.tmpfiles.rules = singleton "d %h/.local/state/kestrel 0700 - - -";

      # systemd user units do not inherit the session's XDG_DATA_DIRS.
      systemd.user.services.ship-shell = {
        description = "Kestrel desktop shell";
        path = [
          pkgs.bluez-tools
          pkgs.brightnessctl
          pkgs.cliphist
          pkgs.ddcutil
          config.programs.hyprland.package
          pkgs.quickshell
          pkgs.uwsm
          pkgs.wl-clipboard
          pkgs.wtype
          config.system.path
          config.home-manager.users.${config.primaryUser}.home.path
        ];
        partOf = singleton "graphical-session.target";
        after = singleton "graphical-session.target";
        wantedBy = singleton "graphical-session.target";

        environment = {
          XDG_DATA_DIRS = "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";
          KESTREL_BROWSER = getExe pkgs.brave;
          KESTREL_EMAIL = getExe pkgs.thunderbird;
          KESTREL_ALLOW_SLEEP = if config.kestrel.allowSleep then "true" else "false";
          KESTREL_IDLE_LOCK_ENABLED = lib.boolToString config.kestrel.idle.lockEnabled;
          KESTREL_IDLE_LOCK_MINUTES = toString config.kestrel.idle.lockMinutes;
          KESTREL_IDLE_DISPLAY_OFF_ENABLED = lib.boolToString config.kestrel.idle.displayOffEnabled;
          KESTREL_IDLE_DISPLAY_OFF_MINUTES = toString config.kestrel.idle.displayOffMinutes;
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
