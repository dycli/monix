# The ship's own quickshell-based desktop shell — scaffolding for the
# DMS replacement (a simple bar; KDE-style settings for live hardware).
# The QML tree in ./qml is the shell; the stock quickshell binary
# interprets it, so there is nothing to compile.
#
# Inert until enabled, and mutually exclusive with DMS by design (two
# shells fight over layer-shell and the notification bus): when this
# graduates, dank.mod.nix leaves the hyprland bundle in the same
# commit that flips this on.
#
# Dev loop: QML hot-reloads from a working checkout —
# `qs -p modules/desktop/shell/qml` — then land here and switch; the
# store symlink itself is read-only.
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

        # Same launch shape as DMS's unit: a user service in the
        # graphical session, with the XDG_DATA_DIRS that systemd user
        # units do not inherit on NixOS.
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
