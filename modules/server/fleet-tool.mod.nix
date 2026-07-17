# The `fleet` dispatch tool and its unprivileged operator identity.
#
# The cockpit (the primary user's fully-privileged interactive session) needs
# to dispatch tasks to the worker fleet and read the results WITHOUT a human
# approving every step — but that standing capability must not be a general
# privilege. So the security boundary is structural, not a permission rule:
#
#   - A dedicated non-wheel system user (`agentFleet.operatorUser`, default
#     `fleet-operator`) OWNS the task queue. wheel can no longer write it.
#   - The cockpit reaches the queue ONLY by running this one `fleet` tool as
#     that operator, via a sudo rule scoped to exactly this binary. The tool
#     is in the read-only nix store, so the very agent it constrains cannot
#     rewrite it (contrast: a script in a user-writable dir is no boundary at
#     all — the agent would just edit it).
#   - `submit` takes the prompt on STDIN, never a path. The redirect that
#     feeds it (`fleet submit < prompt.md`) is opened by the caller's shell
#     with the caller's privileges, so the tool never opens a caller-supplied
#     path and the root drainer never dereferences a caller-supplied symlink
#     (the confused-deputy read that a `cp/mv into the queue` rule allowed).
#
# The cockpit-side Claude allow-rules (which sudo/fleet subcommands run
# without a prompt) are then just ergonomics layered on top of this boundary,
# not the boundary itself.
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
      inherit (lib.strings) concatMapStringsSep fileContents replaceStrings;
      inherit (lib) types;

      cfg = config.agentFleet;
      tasksDir = "/var/lib/agents/tasks";
      op = cfg.operatorUser;
      readers = "agent-fleet-readers";

      # Stable profile path (NOT the store path): sudo matches the command as
      # invoked, and this symlink is what the cockpit calls. It survives
      # rebuilds; `environment.systemPackages` below guarantees it resolves to
      # this exact derivation.
      fleetPath = "/run/current-system/sw/bin/fleet";

      workerHealth = concatMapStringsSep "\n" (w: ''
        if systemctl is-active --quiet microvm@${w.name}.service \
          && [ -f /run/agents/ready/${w.name} ] \
          && [ ! -L /run/agents/ready/${w.name} ]; then
          warm=$((warm + 1))
        fi
        systemctl is-active --quiet agent-dispatch-${w.name}.service && drainers=$((drainers + 1)) || true
      '') cfg.workers;

      fleet = pkgs.writeShellApplication {
        name = "fleet";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.gnutar
          pkgs.gawk
          pkgs.systemd
          pkgs.zstd
        ];
        text =
          replaceStrings
            [
              "@TASKS_DIR@"
              "@TASK_CONTEXT_MAX_BYTES@"
              "@OPERATOR@"
              "@FLEET_PATH@"
              "@WORKER_HEALTH@"
              "@WORKER_COUNT@"
            ]
            [
              tasksDir
              (toString cfg.taskContextMaxBytes)
              op
              fleetPath
              workerHealth
              (toString (lib.lists.length cfg.workers))
            ]
            (fileContents ./fleet-tool/fleet.sh.in);
      };

      # ship-status — the combined ship dashboard, in nushell. Sections are
      # ship systems: BRIDGE (host), REACTOR (memory domains), SYSTEMS
      # (services), DRONE BAY (the fleet), LEDGER (spend, embeds ship-costs),
      # REC DECK (minecraft). Responsive: a wide boxed grid on desktop, stacked
      # single-column on a phone (nu `term size`; SHIP_COLS overrides). Installed
      # as both `ship-status` (the ritual name) and `ship` (short alias).
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

      # `ship` — short alias for the ritual `ship-status`.
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

        # The ONLY path from the cockpit account into the queue: run the fleet
        # tool as the operator. Scoped to this one binary, NOPASSWD so the
        # cockpit's non-interactive `sudo -n` never blocks. wheel has no other
        # write to the queue, so this hop cannot be sidestepped.
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
