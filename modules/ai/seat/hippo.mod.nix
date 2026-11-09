# hippo: the AI seat's episodic memory. One service, running as the seat,
# keeps every chat that passes through Bridge's Libri word for word; sessions
# read it through the `hippo` CLI.
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
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship) topology;
      inherit (topology) seat;

      # The compactor: configuration, never a pick. Each call reaches its
      # model through Libri, on the socket in the store, and runs on Libri's
      # Claude harness, so hippo holds no login and no key. One that can't
      # run fails in `hippo health`; no other model takes its place.
      compactor = {
        HIPPO_BACKEND = "libri";
        HIPPO_MODEL = "haiku";
        HIPPO_EFFORT = "high";
      };

      # Libri's own key, read here because this unit, not Libri, serves the
      # seat's hippo: chat mode keeps what Libri logs, code mode follows the
      # home's sessions too.
      recordAll = (config.services.libri.instances.libri.settings.hippo.record or "libri") == "all";
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
          environment = compactor // {
            HOME = seat.home;
            HIPPO_AGENT = "Bridge";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            User = seat.user;
            Group = seat.user;
            ExecStart = "${lib.meta.getExe (package lib pkgs)} serve ${if recordAll then "code" else "chat"}";
            WorkingDirectory = seat.hippo;
            Restart = "always";
            RestartSec = 5;
            # Recording all, it reads the seat's transcripts; it writes only
            # its own store.
            ProtectHome = "read-only";
            # SQLite needs OpenCode's WAL index writable even to read.
            ReadWritePaths = [ seat.hippo ] ++ lib.optional recordAll "-${seat.home}/.local/share/opencode";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            # The primary user reads the store through the seat's group.
            UMask = "0027";
          };
        };
      };
    };
}
