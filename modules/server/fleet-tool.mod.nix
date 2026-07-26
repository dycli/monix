# The `fleet` dispatch tool and its unprivileged operator identity.
#
# The cockpit needs to dispatch tasks to the worker fleet and read results
# without a human approving every step — but that standing capability must
# not be a general privilege. So the security boundary is structural, not
# a permission rule:
#
#   - A dedicated non-wheel system user (`agentFleet.operatorUser`, default
#     `fleet-operator`) owns the task queue; wheel cannot write it.
#   - The cockpit reaches the queue only by running this one `fleet` tool
#     as that operator, via a sudo rule scoped to exactly this binary. The
#     tool lives in the read-only nix store, so the agent it constrains
#     cannot rewrite it (a script in a user-writable dir would be no
#     boundary at all).
#   - `submit` takes the prompt on stdin, never a path. The redirect that
#     feeds it (`fleet submit < prompt.md`) is opened by the caller's shell
#     with the caller's privileges, so the tool never opens a
#     caller-supplied path and the root drainer never dereferences a
#     caller-supplied symlink.
#
# The cockpit-side Claude allow-rules (which sudo/fleet subcommands run
# without a prompt) are ergonomics layered on top of this boundary, not
# the boundary itself.
{
  flake.nixosModules.fleet-tool =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep fileContents hasSuffix replaceStrings;
      inherit (lib) types;

      cfg = config.agentFleet;
      topology = import ../../lib/fleet-topology.nix;
      inherit (topology) tasksDir;
      op = cfg.operatorUser;
      readers = topology.readersGroup;

      # Stable profile path (not the store path): sudo matches the command
      # as invoked, and this symlink is what the cockpit calls. It survives
      # rebuilds; `environment.systemPackages` below guarantees it resolves
      # to this exact derivation.
      fleetPath = "/run/current-system/sw/bin/fleet";

      # Deployment configuration is baked into the binary at build time
      # (option_env!): caller environment must not repoint the queue or the
      # helper binaries across the sudo boundary.
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

      # ship-status — the combined dashboard, in nushell: host, memory
      # domains, services, the fleet, spend (embeds ship-costs), and
      # minecraft. Responsive: a wide boxed grid on desktop, stacked
      # single-column on a phone (nu `term size`; SHIP_COLS overrides).
      # Installed as both `ship-status` and `ship` (short alias).
      shipStatus = pkgs.writeScriptBin "ship-status" (
        replaceStrings
          [ "@NUSHELL@" "@PATH@" "@WORKERS@" "@OPERATOR@" "@FLEET_PATH@" ]
          [
            (lib.getExe pkgs.nushell)
            (lib.makeBinPath [
              pkgs.coreutils
              pkgs.systemd
              pkgs.mcstatus
              pkgs.tailscale
            ])
            (concatMapStringsSep " " (w: w.name) cfg.workers)
            op
            fleetPath
          ]
          (fileContents ./fleet-tool/ship-status.nu.in)
      );

      # `ship` — short alias for `ship-status`.
      shipAlias = pkgs.runCommand "ship-alias" { } ''
        mkdir -p $out/bin
        ln -s ${shipStatus}/bin/ship-status $out/bin/ship
      '';
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

        environment.systemPackages = [
          fleet
          shipStatus
          shipAlias
        ];

        # The only path from the cockpit account into the queue: run the
        # fleet tool as the operator. Scoped to this one binary, NOPASSWD
        # so the cockpit's non-interactive `sudo -n` never blocks.
        security.sudo.extraRules = [
          {
            users = [ config.primaryUser ];
            runAs = op;
            commands = [
              {
                command = fleetPath;
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];

        # Operator-owned staging for the atomic submit (same filesystem as the
        # queue so the publishing rename is atomic).
        systemd.tmpfiles.rules = [
          "d ${tasksDir}/staging 0700 ${op} ${op} -"
        ];
      };
    };
}
