# Agent-fleet worker guests (docs/agent-fleet.md). Each worker is a minimal
# NixOS microVM, not composed from self.nixosModules — workers are not
# fleet hosts (no tailnet, no monorepo, no host secrets). Containment is
# the host's default-deny egress: the guest has no default route or DNS,
# so the squid allowlist proxy on the bridge IP is the only way out.
#
# The guest root is tmpfs and the nix store is a read-only erofs image of
# the guest closure, opened once at boot as a block device. Sharing the
# host's live store over virtiofs wedges/corrupts running guests (host
# nix-optimise/gc mutates inodes under virtiofsd), so the block-device
# store decouples guests from host store churn. Every worker boots the
# same closure (per-VM identity arrives via kernel command line, never in
# config), so nix builds exactly one image for the fleet. Both volume
# images (store overlay + /workspace scratch) are deleted on every VM
# start (ExecStartPre below), so nothing an agent writes survives a
# restart.
#
# CREDENTIALS: idle guests have an empty read-only credential share. After
# a task is claimed, the host drainer stages exactly the selected
# executor's credential and publishes prompt.md last; the guest installs
# only that credential into the executor's private home. The VM is
# stopped before the host clears the share. Never put secrets in the nix
# store — it's world-readable on the host.
{
  flake.nixosModules.agent-guests =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets)
        listToAttrs
        mapAttrsToList
        nameValuePair
        optionalAttrs
        ;
      inherit (lib.lists) concatLists concatMap singleton;
      inherit (lib.meta) getExe getExe';
      inherit (lib.modules) mkForce mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep fixedWidthString hasSuffix optionalString;
      inherit (lib) types;

      guide = import ../../lib/fleet-guide.nix;
      hintFile = pkgs.writeText "worker-hint.md" (guide.system + guide.worker);

      cfg = config.agentFleet;

      topology = import ../../lib/fleet-topology.nix;
      inherit (topology) hostAddr;
      proxyUrl = "http://${hostAddr}:3128";
      # Local inference bypasses squid (plain HTTP to a bridge IP, which the
      # CONNECT allowlist can't express); the br-agents pinhole fences it instead.
      noProxy = "127.0.0.1,localhost,${hostAddr}";

      # Guest opencode `local` provider, generated from the same
      # inference.models the host serves so guest model ids can't drift
      # from llama-swap. Dispatch as `agent: opencode` + `model: local/<name>`.
      # The ai-sdk loader wants a non-empty apiKey; llama-swap ignores it.
      opencodeConfig = pkgs.writeText "opencode.json" (
        builtins.toJSON (
          {
            "$schema" = "https://opencode.ai/config.json";
          }
          // optionalAttrs config.inference.enable {
            provider.local = {
              npm = "@ai-sdk/openai-compatible";
              name = "ship-local inference (llama-swap)";
              options = {
                baseURL = "http://${hostAddr}:${toString config.inference.port}/v1";
                apiKey = "local";
              };
              models = listToAttrs (
                concatLists (
                  mapAttrsToList (n: m: map (id: nameValuePair id { }) ([ n ] ++ m.aliases)) config.inference.models
                )
              );
            };
          }
        )
      );

      credsDir = name: "/run/agents/creds/${name}";
      guestCredsMount = "/run/host-creds";

      # Per-worker task exchange: the dispatcher writes prompt.md here before
      # boot; agent-task writes report.md/agent.log/exit-code back, and
      # ask-cockpit exchanges question-N.md/answer-N.md mid-task. The guest
      # `agent` user is uid 1000/gid 100, passed through virtiofs verbatim,
      # so the host-side directory is owned by uid 1000.
      workDir = name: "/var/lib/agents/work/${name}/task";
      guestTaskMount = "/run/task";

      # Per-worker volume images, wiped on every VM start (see ExecStartPre).
      volumes = [
        {
          image = "nix-overlay.img"; # writable nix-store overlay
          mountPoint = "/nix/.rw-store";
          size = 8192;
        }
        {
          image = "workspace.img"; # the agent's scratch checkout/build dir
          mountPoint = "/workspace";
          size = 20480;
        }
      ];

      # `index` numbers workers within the fleet and derives both the bridge
      # address (10.100.0.10+index) and a locally-administered MAC; the
      # decimal index doubles as the MAC's last octet (unique for index <= 99).
      mkAgentGuest =
        {
          name,
          index,
          vcpu,
          mem,
          ...
        }:
        let
          addr = "10.100.0.${toString (10 + index)}";
          mac = "02:00:00:00:00:${fixedWidthString 2 "0" (toString index)}";
        in
        {
          # Lifecycle is owned by the resident drainer (warm pool), not systemd autostart.
          autostart = false;

          config =
            { pkgs, ... }:
            let
              # Mid-task escalation: writes a question into the task share and
              # blocks until an answer arrives. Only `guidance: cockpit` tasks
              # reach the live cockpit (`fleet answer`); others get the
              # drainer's stock answer. Capped at 5 questions per task.
              askCockpit = pkgs.writeShellApplication {
                name = "ask-cockpit";
                text = ''
                  if [ $# -lt 1 ]; then
                    echo "usage: ask-cockpit <question...>" >&2
                    exit 2
                  fi
                  task=${guestTaskMount}
                  n=1
                  while [ -e "$task/question-$n.md" ] || [ -e "$task/answer-$n.md" ]; do
                    n=$((n + 1))
                    if [ "$n" -gt 5 ]; then
                      echo "guidance limit (5 questions) reached for this task; proceed on your best judgment" >&2
                      exit 1
                    fi
                  done
                  printf '%s\n' "$*" > "$task/question-$n.md.tmp"
                  mv "$task/question-$n.md.tmp" "$task/question-$n.md"
                  # 30 min: a `guidance: cockpit` task is answered by the live
                  # cockpit (possibly a human), which is slower than a model
                  # advisor. The loop exits the moment an answer lands.
                  for _ in $(seq 1 360); do
                    if [ -e "$task/answer-$n.md" ]; then
                      cat "$task/answer-$n.md"
                      exit 0
                    fi
                    sleep 5
                  done
                  echo "no guidance arrived within 30 minutes; proceed on your best judgment"
                '';
              };

              claudeExecutor = pkgs.writeShellApplication {
                name = "agent-claude-exec";
                text = ''
                  # shellcheck disable=SC1091
                  . /run/agent-claude/env
                  exec ${getExe pkgs.claude-code} "$@"
                '';
              };

              codexExecutor = pkgs.writeShellApplication {
                name = "agent-codex-exec";
                text = ''
                  exec ${getExe pkgs.codex} "$@"
                '';
              };

              # Also serves the credentialless local executor: agent-local
              # can't read /run/agent-opencode/env, so the guard skips it.
              opencodeExecutor = pkgs.writeShellApplication {
                name = "agent-opencode-exec";
                text = ''
                  # shellcheck disable=SC1091
                  [ ! -r /run/agent-opencode/env ] || . /run/agent-opencode/env
                  exec ${getExe pkgs.opencode} "$@"
                '';
              };

              # Guest task supervisor (modules/server/agent-vm/): orchestration,
              # validation, lifecycle, and publication logic, tested in checkPhase.
              guestSupervisor = pkgs.rustPlatform.buildRustPackage {
                pname = "fleet-guest-supervisor";
                version = "0.1.0";
                src = lib.sources.cleanSourceWith {
                  src = ./agent-vm;
                  filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
                };

                cargoLock.lockFile = ./agent-vm/Cargo.lock;
                # Fixture tests drive the same external tools the supervisor uses at runtime.
                nativeCheckInputs = [
                  pkgs.jq
                  pkgs.sqlite
                ];
                meta.mainProgram = "fleet-guest-supervisor";
              };
            in
            {
              microvm = {
                hypervisor = "cloud-hypervisor";
                inherit vcpu mem;

                # Unique per-VM vsock context ID (u32 >= 3); lets guest systemd
                # send readiness notifications to the runner over a host-side
                # unix socket, not a network path out.
                vsock.cid = 100 + index;

                interfaces = singleton {
                  type = "tap";
                  id = "vm-${name}"; # enslaved to br-agents by the networkd vm-* match
                  inherit mac;
                };

                # Erofs image of the guest closure, not a live host-store
                # share (see header) — block device, so host deletion can't touch a running guest.
                storeOnDisk = true;

                # Per-VM identity travels on the kernel command line (host-side
                # runner argument, not part of the guest closure) so the fleet
                # shares one store disk. Adopted at boot by drone-identity below.
                kernelParams = [
                  "drone.name=${name}"
                  "drone.addr=${addr}/24"
                ];

                shares = [
                  # Empty while idle; the drainer stages only the claimed
                  # task's credential before publishing prompt.md.
                  {
                    proto = "virtiofs";
                    tag = "creds";
                    source = credsDir name;
                    mountPoint = guestCredsMount;
                    readOnly = true;
                    cache = "never";
                  }
                  # Task in, report out (see agent-task below).
                  {
                    proto = "virtiofs";
                    tag = "task";
                    source = workDir name;
                    mountPoint = guestTaskMount;
                    # Warm pool delivers prompt.md into a running guest; default
                    # caching would keep a stale negative dentry so the guest
                    # never sees the write. cache=never forces revalidation.
                    cache = "never";
                  }
                ];

                # Writable overlay so `nix build` works inside the guest.
                writableStoreOverlay = "/nix/.rw-store";
                inherit volumes;
              };

              # NETWORKING — static address on the host-only bridge subnet, no
              # gateway and no DNS: the guest cannot route or resolve anything;
              # squid resolves on its behalf. Address/hostname come from the
              # kernel command line so the closure stays identical across
              # workers; drone-identity writes the networkd unit into /run
              # before networkd starts. Per-VM address enforcement lives
              # host-side on the tap, not here.
              networking.useNetworkd = true;
              networking.useDHCP = false;
              networking.hostName = "drone"; # overridden at boot from cmdline
              systemd.services.drone-identity = {
                description = "Adopt per-VM identity from the kernel command line";
                wantedBy = [ "sysinit.target" ];
                before = [ "systemd-networkd.service" ];
                requiredBy = [ "systemd-networkd.service" ];
                unitConfig.DefaultDependencies = false;
                serviceConfig.Type = "oneshot";
                serviceConfig.RemainAfterExit = true;
                script = ''
                  name= addr=
                  read -r cmdline < /proc/cmdline
                  for word in $cmdline; do
                    case "$word" in
                      drone.name=*) name=''${word#drone.name=} ;;
                      drone.addr=*) addr=''${word#drone.addr=} ;;
                    esac
                  done
                  if [ -n "$name" ]; then
                    printf '%s' "$name" > /proc/sys/kernel/hostname
                  fi
                  if [ -n "$addr" ]; then
                    mkdir -p /run/systemd/network
                    printf '[Match]\nType=ether\n\n[Network]\nAddress=%s\n' \
                      "$addr" > /run/systemd/network/20-lan.network
                  fi
                '';
              };

              # networking.proxy covers lowercase env vars plus nix-daemon;
              # Claude Code and Codex (Node) want uppercase, set explicitly.
              networking.proxy.default = proxyUrl;
              networking.proxy.noProxy = noProxy;
              environment.variables = {
                HTTP_PROXY = proxyUrl;
                HTTPS_PROXY = proxyUrl;
                NO_PROXY = noProxy;
                # opencode reads its provider catalog from this read-only store path.
                OPENCODE_CONFIG = "${opencodeConfig}";
              };

              environment.systemPackages = [
                askCockpit
                claudeExecutor
                codexExecutor
                opencodeExecutor
                pkgs.git
                pkgs.ripgrep
                pkgs.fd
                pkgs.jq
                pkgs.sqlite # usage.json extraction reads opencode's SQLite store
                pkgs.curl
                pkgs.gnumake
                pkgs.gcc
                pkgs.gnutar
                pkgs.procps
                pkgs.util-linux
                pkgs.zstd
              ];

              nix.settings.experimental-features = [
                "flakes"
                "nix-command"
              ];
              # Substituters stay at cache.nixos.org — the only cache on the egress allowlist.

              # fleet-guest-supervisor waits for a delivered prompt, runs it
              # headless as the selected agent user, and writes results back.
              # Type=exec, not oneshot: the VM unit is Type=notify via vsock
              # and expects readiness once boot settles; a oneshot's start job
              # would last for the whole task, holding the host-side
              # `systemctl start microvm@<name>` until its 150s timeout.
              systemd.services.agent-task = {
                description = "Run the dispatched task";
                wantedBy = [ "multi-user.target" ];
                unitConfig = {
                  # No ConditionPathExists on prompt.md: the guest boots idle
                  # and the supervisor's wait loop blocks for a delivered
                  # task, so gating on the file's existence would skip a warm boot entirely.
                  RequiresMountsFor = [
                    guestTaskMount
                    guestCredsMount
                  ];
                };
                # Full system path: the agent's shell inherits this unit's
                # PATH and needs everything in the guest (git, ask-cockpit,
                # compilers...); the supervisor also resolves its fixed
                # helper tools (runuser, tar, git, jq, sqlite3, cp, chown, pkill) from it.
                path = [ "/run/current-system/sw" ];
                serviceConfig = {
                  Type = "exec";
                  User = "root";
                  Group = "root";
                  WorkingDirectory = "/workspace";
                  # The prompt may carry a front-matter block, but the guest
                  # never reparses executor fields from it: canonical
                  # task-meta (agent, model, effort, kind) is staged by the
                  # host in the read-only credential share instead.
                  ExecStart = getExe guestSupervisor;
                  # Units don't read /etc/set-environment; restate the proxy.
                  # The Bash timeouts let a blocking ask-cockpit call outlive
                  # Claude Code's 2-minute default tool timeout.
                  Environment = [
                    "HTTP_PROXY=${proxyUrl}"
                    "HTTPS_PROXY=${proxyUrl}"
                    "NO_PROXY=${noProxy}"
                    "OPENCODE_CONFIG=${opencodeConfig}"
                    "BASH_DEFAULT_TIMEOUT_MS=1200000"
                    "BASH_MAX_TIMEOUT_MS=1800000"
                    "FLEET_GUEST_TASK_DIR=${guestTaskMount}"
                    "FLEET_GUEST_CREDS_DIR=${guestCredsMount}"
                    "FLEET_GUEST_HINT_FILE=${hintFile}"
                    "FLEET_GUEST_EXEC_CLAUDE=${getExe claudeExecutor}"
                    "FLEET_GUEST_EXEC_CODEX=${getExe codexExecutor}"
                    "FLEET_GUEST_EXEC_OPENCODE=${getExe opencodeExecutor}"
                    "FLEET_GUEST_EXEC_LOCAL=${getExe opencodeExecutor}"
                  ];
                  # No single guest-created file may grow unbounded.
                  LimitFSIZE = cfg.taskExchangeMaxBytes;
                };
              };

              # Local git captures a patch against the cockpit-built baseline;
              # workers have no forge credentials or GitHub route. Constant
              # author identity: per-VM values would fork the guest closure
              # and break the shared store disk.
              programs.git = {
                enable = true;
                config = {
                  user.name = "drone";
                  user.email = "drone@agents.invalid";
                };
              };

              # Executor identities share the disposable workspace but have
              # private 0700 homes, no wheel/sudo, and distinct UIDs (blocks
              # ptrace and cross-executor process access).
              users.users = {
                agent-claude = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "Claude fleet executor";
                };
                agent-codex = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "Codex fleet executor";
                };
                agent-opencode = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "opencode fleet executor";
                };
                agent-local = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "credentialless local-model fleet executor";
                };
              };
              systemd.tmpfiles.rules = singleton "d /workspace 0770 root users -";

              # Root autologin on the serial console: reaching it at all
              # requires host-root (the microvm@ unit's PTY); guest
              # containment never rests on in-guest auth.
              services.getty.autologinUser = "root";

              system.stateVersion = "26.05";
            };
        };
    in
    {
      # The fleet roster; the VM definition and slice fence are generated from this list.
      options.agentFleet = {
        workers = mkOption {
          description = "agent-fleet worker roster";
          default = [ ];
          type = types.listOf (
            types.submodule {
              options = {
                name = mkOption { type = types.str; };
                index = mkOption { type = types.ints.between 1 99; };
                vcpu = mkOption {
                  type = types.int;
                  default = 8;
                };
                mem = mkOption {
                  type = types.int;
                  default = 8192; # MiB, static, no ballooning
                };
              };
            }
          );
        };

        # The host drainer reads these paths at dispatch time and stages
        # only the credential selected by that task.
        credentials = {
          claudeTokenFile = mkOption {
            type = types.str;
            description = "host path of the Claude Code OAuth token (from `claude setup-token`)";
          };
          codexAuthFile = mkOption {
            type = types.str;
            description = "host path of a copy of Codex's auth.json (from a ChatGPT login)";
          };
          openrouterKeyFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "host path of an OpenRouter API key (single line, from openrouter.ai/keys); null = opencode dispatch has no credential and fails auth";
          };
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion =
              lib.lists.length cfg.workers == lib.lists.length (lib.lists.unique (map (w: w.name) cfg.workers));
            message = "agentFleet worker names must be unique";
          }
          {
            assertion =
              lib.lists.length cfg.workers == lib.lists.length (lib.lists.unique (map (w: w.index) cfg.workers));
            message = "agentFleet worker indices must be unique";
          }
        ];

        microvm.vms = listToAttrs (map (w: nameValuePair w.name (mkAgentGuest w)) cfg.workers);

        # Share sources must exist before virtiofsd starts. The task exchange
        # is guest-writable; the credential source is root-only and empty
        # until the drainer stages one for a claimed task.
        systemd.tmpfiles.rules = concatMap (w: [
          "d ${workDir w.name} 0770 root users -"
          "d ${credsDir w.name} 0700 root root -"
        ]) cfg.workers;

        systemd.services = listToAttrs (
          map (
            w:
            # microvm.nix has no slice option; unit override so every worker
            # counts against the fleet's 48G/agents.slice fence.
            (nameValuePair "microvm@${w.name}" {
              serviceConfig = {
                Slice = "agents.slice";
                # The drainer owns worker lifecycle; upstream's Restart=always would fight its stop/start.
                Restart = mkForce "no";
                # Guest volumes are wiped on next start, so a graceful
                # poweroff buys nothing. SIGKILL is the intended kill signal
                # (not upstream's microvm-shutdown ExecStop), so every stop
                # is instant and records as success rather than a timeout
                # failure (which would trip the OnFailure Matrix alert).
                # [ "" ] resets the ExecStop list — a drop-in can only clear
                # a directive from the shared microvm@.service template explicitly.
                ExecStop = mkForce [ "" ];
                KillSignal = "SIGKILL";
                # systemd only treats TERM/HUP/INT/PIPE as clean deaths; our
                # own KillSignal must be declared expected or it records result=signal.
                SuccessExitStatus = "SIGKILL";
                TimeoutStopSec = mkForce 3;
                # Delete the volume images before every start; the runner's
                # autoCreate recreates them blank, so each boot is a clean slate.
                ExecStartPre = singleton (
                  "${getExe' pkgs.coreutils "rm"} -f "
                  + concatMapStringsSep " " (v: "${config.microvm.stateDir}/${w.name}/${v.image}") volumes
                );
              };
            })
          ) cfg.workers
        );
      };
    };
}
