# hippo: the AI seat's episodic memory. One service, running as the seat,
# follows its Claude Code, Codex and OpenCode transcripts live and logs
# every chat word for word; sessions read it through the `hippo` CLI.
# Design: ~/cockpit/hippo/SPEC.md.
{ self, ... }:
let
  package =
    lib: pkgs:
    lib.ship.rustTool pkgs {
      src = ./hippo;
      env.HIPPO_DIR = lib.ship.topology.seat.hippo;
    };
in
{
  # Straight into the seat's bundle: a homeModules.hippo would be mirrored
  # onto the host's primary user (options/flake-outputs.mod.nix).
  flake.homeModules.cockpit =
    { lib, pkgs, ... }:
    {
      home.packages = lib.lists.singleton (package lib pkgs);
    };

  flake.nixosModules.seat = self.nixosModules.hippo;
  flake.nixosModules.hippo =
    { lib, pkgs, ... }:
    let
      inherit (lib.ship.topology) seat;
    in
    {
      systemd.tmpfiles.rules = lib.lists.singleton "d ${seat.hippo} 0750 ${seat.user} ${seat.user} -";

      systemd.services.hippo = {
        description = "hippo, the AI seat's episodic memory";
        wantedBy = lib.lists.singleton "multi-user.target";
        unitConfig.RequiresMountsFor = [
          "/srv/storage"
          seat.home
        ];
        environment.HOME = seat.home;
        serviceConfig = lib.ship.hardened.tenant // {
          User = seat.user;
          Group = seat.user;
          ExecStart = "${lib.meta.getExe (package lib pkgs)} serve";
          Restart = "always";
          RestartSec = 5;
          # Reads the seat's transcripts; writes only its own store.
          ProtectHome = "read-only";
          # SQLite needs OpenCode's WAL index writable even to read.
          ReadWritePaths = [
            seat.hippo
            "-${seat.home}/.local/share/opencode"
          ];
          # No model yet: the CLI socket is all it speaks.
          PrivateNetwork = true;
          RestrictAddressFamilies = "AF_UNIX";
          # The primary user reads the store through the seat's group.
          UMask = "0027";
        };
      };
    };
}
