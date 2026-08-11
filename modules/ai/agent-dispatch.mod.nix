# Agent-fleet dispatcher: one resident drainer per worker keeps a warm VM,
# claims queued markdown prompts, archives the results and reboots the guest.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.agent-dispatch;
  flake.nixosModules.agent-dispatch =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) listToAttrs nameValuePair;
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) hasSuffix;
      inherit (lib) types;

      cfg = config.agentFleet;
      op = cfg.operatorUser;
      inherit (lib.ship) topology;
      inherit (topology) tasksDir;
      readers = topology.readersGroup;
      agentDispatcher = pkgs.rustPlatform.buildRustPackage {
        pname = "agent-dispatcher";
        version = "0.1.0";
        src = lib.sources.cleanSourceWith {
          src = ./agent-dispatch;
          filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
        };

        cargoLock.lockFile = ./agent-dispatch/Cargo.lock;
        meta.mainProgram = "agent-dispatcher";
      };

      drainerFor =
        worker:
        let
          work = "/var/lib/agents/work/${worker}/task";
          creds = "/run/agents/creds/${worker}";
        in
        {
          description = "Drain the agent task queue on worker ${worker}";
          wantedBy = singleton "multi-user.target";
          startLimitIntervalSec = 0;
          path = [
            pkgs.coreutils
            pkgs.jq
            pkgs.systemd
          ];
          serviceConfig = {
            ExecStart = getExe agentDispatcher;
            Restart = "always";
            RestartSec = 2;

            # Root is required for cross-user chown and VM lifecycle over
            # D-Bus, which rules out PrivateUsers and a capability clamp.
            LockPersonality = true;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            ProtectSystem = "strict";
            ReadWritePaths = [
              "/var/lib/agents"
              "/run/agents"
            ];
            RestrictAddressFamilies = singleton "AF_UNIX";
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            SocketBindDeny = "any";
            SystemCallArchitectures = "native";
            SystemCallFilter = singleton "@system-service";
            SystemCallErrorNumber = "EPERM";
          };
          environment = {
            FLEET_TASKS_DIR = tasksDir;
            FLEET_WORKER = worker;
            FLEET_WORK_DIR = work;
            FLEET_CREDS_DIR = creds;
            FLEET_CLAUDE_TOKEN_FILE = cfg.credentials.claudeTokenFile;
            FLEET_CODEX_AUTH_FILE = cfg.credentials.codexAuthFile;
            FLEET_OPENROUTER_KEY_FILE =
              if cfg.credentials.openrouterKeyFile == null then
                ""
              else
                toString cfg.credentials.openrouterKeyFile;
            FLEET_READERS = readers;
            FLEET_STALL_TIMEOUT = toString cfg.stallTimeout;
            FLEET_WARM_MAX_AGE = toString cfg.warmMaxAge;
            FLEET_TASK_TIMEOUT = toString cfg.taskTimeout;
            FLEET_TASK_EXCHANGE_MAX_BYTES = toString cfg.taskExchangeMaxBytes;
            FLEET_TASK_CONTEXT_MAX_BYTES = toString cfg.taskContextMaxBytes;
          };
        };
    in
    {
      options.agentFleet.stallTimeout = mkOption {
        type = types.int;
        default = 120;
        description = "seconds with no guest heartbeat before a task is treated as stalled/dead and killed";
      };

      options.agentFleet.warmMaxAge = mkOption {
        type = types.int;
        default = 7200;
        description = "seconds an idle warm VM may live before it is preventively destroyed and rebooted";
      };

      options.agentFleet.taskTimeout = mkOption {
        type = types.int;
        default = 21600;
        description = "absolute max seconds a task may run before the worker is stopped and the task filed as failed, regardless of progress";
      };

      options.agentFleet.taskExchangeMaxBytes = mkOption {
        type = types.int;
        default = 805306368;
        description = "maximum total bytes in one live worker task exchange before the task is stopped";
      };

      options.agentFleet.taskContextMaxBytes = mkOption {
        type = types.int;
        default = 536870912;
        description = "maximum compressed context capsule bytes accepted for one task";
      };

      config = mkIf (cfg.workers != [ ]) {
        systemd.tmpfiles.rules = [
          "d ${tasksDir} 0755 root root -"
          "d ${tasksDir}/queue 0770 root ${op} -"
          "d ${tasksDir}/running 0755 root root -"
          "d ${tasksDir}/done 0750 root ${readers} -"
          "d ${tasksDir}/failed 0750 root ${readers} -"
          "d ${tasksDir}/rejected 0750 root ${readers} -"
          "d ${tasksDir}/live 0750 root ${readers} -"
          "d ${tasksDir}/steer 0770 root ${op} -"
          "d ${tasksDir}/answers 0770 root ${op} -"
          "d ${tasksDir}/cancel 0770 root ${op} -"
          # Operator writes, readers read via ACL, world gets nothing: the log
          # carries task ids, models and usernames.
          "f ${tasksDir}/log 0660 root ${op} -"
          "a+ ${tasksDir}/log - - - - group:${readers}:r"
        ];

        systemd.services = listToAttrs (
          map (w: nameValuePair "agent-dispatch-${w.name}" (drainerFor w.name)) cfg.workers
        );
      };
    };
}
