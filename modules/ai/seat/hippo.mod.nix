# hippo: Bridge's Libri's record. One service, running as the seat, keeps
# every chat that passes through Bridge's Libri word for word; hippo2 reads
# that record into the memory every session recalls from (hippo2.mod.nix).
# Design: README, "hippo".
{ self, ... }:
let
  # Libri's repository holds hippo; the seat runs the build its link points
  # at, as Libri does (deploy_libri.sh keeps the link).
  package =
    lib: pkgs:
    lib.ship.libriHippo pkgs lib.ship.topology.seat.libriBuild {
      HIPPO_DIR = lib.ship.topology.seat.hippo;
      HIPPO_ARCHIVE = lib.ship.topology.seat.transcripts;
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
      inherit (lib.lists) singleton;
      inherit (lib.ship) topology;
      inherit (topology) seat;
    in
    {
      config = {
        # hippo is the only memory: Codex's own stays off.
        seat.codexConfig.features.memories = false;

        systemd.tmpfiles.rules = singleton "d ${seat.hippo} 0750 ${seat.user} ${seat.user} -";

        # A store is bootstrapped by `hippo import` (every past chat) before anything live enters it; the service starts once the
        # import has written its record.
        systemd.paths.hippo = {
          wantedBy = singleton "paths.target";
          pathConfig.PathExists = "${seat.hippo}/import.json";
        };

        systemd.services.hippo = {
          description = "hippo, the AI seat's episodic memory";
          wantedBy = singleton "multi-user.target";
          unitConfig.ConditionPathExists = "${seat.hippo}/import.json";
          # A switch restarts it after the reload: stopped first, hippo.path
          # would start it again on the old unit before the new one loads.
          stopIfChanged = false;
          after = singleton "network-online.target";
          wants = singleton "network-online.target";
          unitConfig.RequiresMountsFor = [
            "/srv/storage"
            seat.home
          ];
          environment = {
            # It writes no summaries: it keeps Libri's record alone, and
            # hippo2 (hippo2.mod.nix) is the memory every turn recalls from.
            HIPPO_BACKEND = "none";
            HOME = seat.home;
            HIPPO_AGENT = "Bridge";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            User = seat.user;
            Group = seat.user;
            ExecStart = "${lib.meta.getExe (package lib pkgs)} serve chat";
            WorkingDirectory = seat.hippo;
            Restart = "always";
            RestartSec = 5;
            # It writes only its own store.
            ProtectHome = "read-only";
            ReadWritePaths = singleton seat.hippo;
            RestrictAddressFamilies = singleton "AF_UNIX";
            # The primary user reads the store through the seat's group.
            UMask = "0027";
          };
        };
      };
    };
}
