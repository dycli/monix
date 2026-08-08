# The `fleet` dispatch tool and its unprivileged operator identity: a
# non-wheel system user owns the queue, reachable only through a scoped sudo
# rule naming this one store-resident binary.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.fleet-tool;
  flake.nixosModules.fleet-tool =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) optionals;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep hasSuffix;
      inherit (lib) types;

      cfg = config.agentFleet;
      inherit (lib.ship) topology;
      inherit (topology) tasksDir;
      op = cfg.operatorUser;
      readers = topology.readersGroup;

      # sudo matches the command as invoked, so the rule names this stable
      # profile path rather than a store path.
      fleetPath = "/run/current-system/sw/bin/fleet";

      # Baked in at build time with option_env!, so a caller's environment
      # cannot repoint the queue or the helpers across the sudo boundary.
      fleet = pkgs.rustPlatform.buildRustPackage {
        pname = "fleet";
        version = "0.1.0";
        src = lib.sources.cleanSourceWith {
          src = ./fleet-tool/fleet-cli;
          filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
        };
        cargoLock.lockFile = ./fleet-tool/fleet-cli/Cargo.lock;
        env = {
          FLEET_TASKS_DIR = tasksDir;
          FLEET_CONTEXT_MAX_BYTES = toString cfg.taskContextMaxBytes;
          FLEET_TASK_TIMEOUT = toString cfg.taskTimeout;
          FLEET_OPERATOR = op;
          FLEET_SELF = fleetPath;
          FLEET_WORKERS = concatMapStringsSep " " (w: w.name) cfg.workers;
          FLEET_TAR = "${pkgs.gnutar}/bin/tar";
          FLEET_ZSTD = "${pkgs.zstd}/bin/zstd";
          FLEET_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";
        };
        meta.mainProgram = "fleet";
      };

    in
    {
      options.agentFleet.operatorUser = mkOption {
        type = types.str;
        default = "fleet-operator";
        description = ''
          Unprivileged system user that owns the dispatch queue. The cockpit
          reaches the queue only by running the `fleet` tool as this user via a
          scoped sudo rule — this account, not the Claude permission list, is
          the dispatch security boundary. It is non-wheel, has no shell login,
          and can do nothing but enqueue tasks and read results.
        '';
      };

      config = mkIf (cfg.enable && cfg.workers != [ ]) {
        users.groups.${readers} = { };
        users.groups.${op} = { };
        users.users.${op} = {
          isSystemUser = true;
          group = op;
          extraGroups = [ readers ];
          description = "agent-fleet dispatch operator";
        };
        users.users.${config.primaryUser}.extraGroups = [ readers ];
        users.users.bridge = mkIf config.cockpit.enable { extraGroups = [ readers ]; };

        environment.systemPackages = [ fleet ];

        # The only path into the queue. NOPASSWD so a non-interactive
        # `sudo -n` never blocks.
        security.sudo.extraRules = [
          {
            users = [ config.primaryUser ] ++ optionals config.cockpit.enable [ "bridge" ];
            runAs = op;
            commands = [
              {
                command = fleetPath;
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];

        # On the same filesystem as the queue so the publishing rename is
        # atomic.
        systemd.tmpfiles.rules = [
          "d ${tasksDir}/staging 0700 ${op} ${op} -"
        ];
      };
    };
}
