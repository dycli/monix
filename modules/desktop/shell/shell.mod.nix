# An in-tree quickshell desktop shell, off unless shipShell.enable is set. The
# QML tree in ./qml is the shell; the stock quickshell binary interprets it.
#
# Mutually exclusive with DMS, which contends for layer-shell and the
# notification bus, so enabling this requires removing dank.mod.nix from the
# hyprland bundle. The store copy is read-only; iterate against a working
# checkout with `qs -p modules/desktop/shell/qml`, which hot-reloads.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.ship-shell;
  flake.nixosModules.ship-shell =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.meta) getExe;
      inherit (lib.options) mkEnableOption;

      cfg = config.shipShell;
    in
    {
      options.shipShell.enable = mkEnableOption "the ship's own quickshell desktop shell";

      config = mkIf cfg.enable {
        environment.systemPackages = [ pkgs.quickshell ];

        # systemd user units do not inherit the session's XDG_DATA_DIRS.
        systemd.user.services.ship-shell = {
          description = "ship quickshell desktop shell";
          partOf = [ "graphical-session.target" ];
          after = [ "graphical-session.target" ];
          wantedBy = [ "graphical-session.target" ];

          environment.XDG_DATA_DIRS = "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";

          serviceConfig = {
            ExecStart = "${getExe pkgs.quickshell} -p ${./qml}";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      };
    };
}
