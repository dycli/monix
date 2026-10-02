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

      cfg = config.agentFleet;
      inherit (lib.ship) topology;
      inherit (topology) limits tasksDir;
      op = topology.operator;
      readers = topology.readersGroup;
      agentDispatcher = pkgs.rustPlatform.buildRustPackage {
        pname = "agent-dispatcher";
        version = "0.1.0";
        src = ./agent-dispatch;

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
            # D-Bus (authorized by uid, not capability), which rules out
            # PrivateUsers — but not a capability clamp: only the
            # file-ownership work needs privilege.
            CapabilityBoundingSet = [
              "CAP_CHOWN"
              "CAP_DAC_OVERRIDE"
              "CAP_FOWNER"
            ];
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
            FLEET_OPENCODE_KEY_FILE = cfg.credentials.opencodeKeyFile;
            FLEET_READERS = readers;
            FLEET_WORK_GROUP = topology.guestGroup;
            FLEET_STALL_TIMEOUT = toString limits.stallTimeout;
            FLEET_WARM_MAX_AGE = toString limits.warmMaxAge;
            FLEET_TASK_TIMEOUT = toString limits.taskTimeout;
            FLEET_TASK_EXCHANGE_MAX_BYTES = toString limits.taskExchangeMaxBytes;
            FLEET_TASK_CONTEXT_MAX_BYTES = toString limits.taskContextMaxBytes;
          };
        };
    in
    {
      config = {
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

        systemd.services =
          cfg.workers |> map (name: nameValuePair "agent-dispatch-${name}" (drainerFor name)) |> listToAttrs;
      };
    };
}
