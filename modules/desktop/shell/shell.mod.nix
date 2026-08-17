# The Kestrel desktop shell. DMS stays running for the features not yet aboard;
# its bar is hidden before Kestrel claims the top edge.
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

      # systemd user units do not inherit the session's XDG_DATA_DIRS.
      systemd.user.services.ship-shell = {
        description = "Kestrel desktop shell";
        partOf = singleton "graphical-session.target";
        after = [
          "graphical-session.target"
          "dms.service"
        ];
        wantedBy = singleton "graphical-session.target";

        environment.XDG_DATA_DIRS = "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";

        serviceConfig = {
          ExecStartPre = "${getExe config.programs.dms-shell.package} ipc call bar hide";
          ExecStart = "${getExe pkgs.quickshell} -p ${./qml}";
          Restart = "on-failure";
          RestartSec = 1;
        };
      };
    };
}
