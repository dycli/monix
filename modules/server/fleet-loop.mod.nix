# Durable outer-loop orchestration for the disposable agent fleet. The Rust
# controller owns only loop policy/state and submits ordinary bounded tasks;
# provider credentials remain staged per implementation task by the existing
# root drainer. Verification is a credentialless fixed-harness task in a fresh VM.
{
  flake.nixosModules.fleet-loop =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption;
      cfg = config.agentFleet;
      op = cfg.operatorUser;
      topology = import ../../lib/fleet-topology.nix;
      inherit (topology) loopsDir tasksDir;
      readers = topology.readersGroup;
      fleetLoopEngine = import ../../lib/fleet-loop-package.nix { inherit pkgs; };
    in
    {
      options.agentFleet.loops.enable = mkEnableOption "durable outer loops across disposable fleet VMs";

      config = mkIf (cfg.enable && cfg.loops.enable && cfg.workers != [ ]) {
        environment.systemPackages = [ fleetLoopEngine ];

        systemd.tmpfiles.rules = [
          # setgid keeps every operator-created loop readable by the cockpit's
          # agent-fleet-readers group without giving it write authority.
          "d ${loopsDir} 2770 ${op} ${readers} -"
          "d ${loopsDir}/staging 0700 ${op} ${op} -"
        ];

        systemd.services.fleet-loop-permissions = {
          description = "Migrate durable fleet loop permissions";
          path = [
            pkgs.coreutils
            pkgs.findutils
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ loopsDir ];
          };
          script = ''
            if [ ! -e ${loopsDir}/.readers-v3 ]; then
              for loop in ${loopsDir}/*; do
                [ -d "$loop" ] || continue
                [ "$loop" != ${loopsDir}/staging ] || continue
                chgrp -hR ${readers} "$loop"
                find "$loop" -xdev -type d -exec chmod 2750 {} +
                find "$loop" -xdev -type f -exec chmod 0640 {} +
              done
              touch ${loopsDir}/.readers-v3
            fi
          '';
        };

        systemd.services.fleet-loop-controller = {
          description = "Advance durable agent-fleet outer loops";
          wantedBy = [ "multi-user.target" ];
          requires = [ "fleet-loop-permissions.service" ];
          after = [
            "agent-results-permissions.service"
            "fleet-loop-permissions.service"
          ];
          path = [
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnutar
            pkgs.zstd
          ];
          environment = {
            FLEET_TASKS_DIR = tasksDir;
            FLEET_LOOPS_DIR = loopsDir;
            FLEET_BIN = "/run/current-system/sw/bin/fleet";
            FLEET_CONTEXT_MAX = toString cfg.taskContextMaxBytes;
            FLEET_TASK_TIMEOUT = toString cfg.taskTimeout;
          };
          serviceConfig = {
            Type = "exec";
            User = op;
            Group = readers;
            SupplementaryGroups = [ op ];
            Slice = "agents.slice";
            UMask = "0027";
            Restart = "always";
            RestartSec = 2;

            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            ReadWritePaths = [
              loopsDir
              # submit-capsule atomically hard-links staging files into the
              # queue, so both paths must share one mount in this namespace.
              # Unix ownership still limits fleet-operator to its existing
              # queue/staging/cancel/log authority within this tree.
              tasksDir
            ];
          };
          preStart = ''
            probe=$(mktemp ${tasksDir}/staging/.loop-link-test.XXXXXXXX)
            probe_link=${tasksDir}/queue/.$(basename "$probe")
            trap 'rm -f "$probe" "$probe_link"' EXIT
            ln "$probe" "$probe_link"
            rm -f "$probe" "$probe_link"
            trap - EXIT

          '';
          script = ''
            exec ${fleetLoopEngine}/bin/fleet-loop-engine daemon
          '';
        };
      };
    };
}
