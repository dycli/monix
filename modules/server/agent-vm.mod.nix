# Agent-fleet worker guests. Each worker is a minimal NixOS microVM,
# deliberately not composed from self.nixosModules: workers get no
# tailnet, no monorepo and no host secrets. The guest has no default
# route or DNS, so the squid allowlist on the bridge IP is the only exit.
#
# Guest root is tmpfs and the nix store is a read-only erofs image opened
# as a block device. Sharing the host's live store over virtiofs corrupts
# running guests, since host gc and nix-optimise mutate inodes underneath
# virtiofsd. Every worker boots the same closure, with per-VM identity
# arriving on the kernel command line, so one image is built for the
# fleet. Both volume images are deleted on VM start.
#
# Idle guests have an empty read-only credential share. Once a task is
# claimed the host stages only the selected executor's credential and
# publishes prompt.md last; the VM is stopped before the share is
# cleared. Secrets must never go in the nix store, which is
# world-readable on the host.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.agent-guests;
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
      inherit (lib.strings)
        concatMapStringsSep
        fixedWidthString
        hasSuffix
        optionalString
        toJSON
        ;
      inherit (lib) types;

      guide = lib.ship.guide;
      hintFile = pkgs.writeText "worker-hint.md" (guide.system + guide.worker);

      cfg = config.agentFleet;

      topology = lib.ship.topology;
      inherit (topology) hostAddr;
      proxyUrl = "http://${hostAddr}:3128";
      # Local inference is plain HTTP to a bridge IP, which a CONNECT
      # allowlist cannot express, so it uses the br-agents pinhole.
      noProxy = "127.0.0.1,localhost,${hostAddr}";

      # Generated from the same inference.models the host serves, so guest
      # model ids cannot drift. The ai-sdk loader requires a non-empty
      # apiKey, which llama-swap ignores.
      opencodeConfig = pkgs.writeText "opencode.json" (
        toJSON (
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

      # Task exchange: prompt.md in, report.md/agent.log/exit-code out,
      # question-N.md/answer-N.md mid-task. virtiofs passes uid/gid
      # verbatim, so this host directory must be owned by uid 1000.
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

      # `index` derives the bridge address (10.100.0.10+index) and the MAC,
      # whose last octet is the decimal index; unique for index <= 99.
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
          # The resident drainer owns lifecycle, not systemd autostart.
          autostart = false;

          config =
            { pkgs, ... }:
            let
              # Writes a question into the task share and blocks for an
              # answer. Only `guidance: cockpit` tasks reach the cockpit;
              # others get the drainer's stock reply. Five per task.
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
                  # 30 min, since a human may be answering. The loop exits
                  # as soon as an answer lands.
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

              # agent-local has no credential to read, so the guard skips it.
              opencodeExecutor = pkgs.writeShellApplication {
                name = "agent-opencode-exec";
                text = ''
                  # shellcheck disable=SC1091
                  [ ! -r /run/agent-opencode/env ] || . /run/agent-opencode/env
                  exec ${getExe pkgs.opencode} "$@"
                '';
              };

              # Guest task supervisor: orchestration, validation, lifecycle
              # and publication, tested in checkPhase.
              guestSupervisor = pkgs.rustPlatform.buildRustPackage {
                pname = "fleet-guest-supervisor";
                version = "0.1.0";
                src = lib.sources.cleanSourceWith {
                  src = ./agent-vm;
                  filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
                };

                cargoLock.lockFile = ./agent-vm/Cargo.lock;
                # Fixtures drive the same tools the supervisor uses at runtime.
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

                # Per-VM vsock context id (u32 >= 3), carrying guest systemd
                # readiness over a unix socket rather than the network.
                vsock.cid = 100 + index;

                interfaces = singleton {
                  type = "tap";
                  id = "vm-${name}"; # enslaved to br-agents by the networkd vm-* match
                  inherit mac;
                };

                # Erofs image of the guest closure as a block device, so host
                # store deletion cannot affect a running guest.
                storeOnDisk = true;

                # Per-VM identity travels on the kernel command line, outside
                # the guest closure, so the fleet shares one store disk.
                kernelParams = [
                  "drone.name=${name}"
                  "drone.addr=${addr}/24"
                ];

                shares = [
                  # Empty while idle; the drainer stages one credential.
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
                    # prompt.md appears in a running guest, and default
                    # caching would keep a stale negative dentry so the guest
                    # never sees the write. cache=never forces revalidation.
                    cache = "never";
                  }
                ];

                # Writable overlay so `nix build` works inside the guest.
                writableStoreOverlay = "/nix/.rw-store";
                inherit volumes;
              };

              # Static address on the host-only bridge, no gateway and no
              # DNS, so the guest cannot route or resolve; squid resolves on
              # its behalf. Address and hostname come from the kernel command
              # line, written into /run by drone-identity before networkd
              # starts, so the closure stays identical across workers.
              #
              # The address is assigned but not enforced — nothing pins a tap
              # to its MAC — so a guest could spoof toward the host. The
              # bridge's Isolated flag still blocks guest-to-guest traffic.
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

              # networking.proxy sets the lowercase vars and nix-daemon;
              # the Node-based executors read the uppercase ones.
              networking.proxy.default = proxyUrl;
              networking.proxy.noProxy = noProxy;
              environment.variables = {
                HTTP_PROXY = proxyUrl;
                HTTPS_PROXY = proxyUrl;
                NO_PROXY = noProxy;
                # opencode reads its provider catalog from this path.
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
              # cache.nixos.org is the only cache on the egress allowlist.

              # Waits for a delivered prompt, runs it as the selected agent
              # user and writes results back. Type=exec rather than oneshot:
              # the VM unit is Type=notify and expects readiness at boot,
              # while a oneshot's start job would last the whole task and
              # hold the host's `systemctl start` to its timeout.
              systemd.services.agent-task = {
                description = "Run the dispatched task";
                wantedBy = [ "multi-user.target" ];
                unitConfig = {
                  # No ConditionPathExists on prompt.md: the guest boots idle
                  # and the supervisor blocks for a task, so gating on the
                  # file would skip a warm boot entirely.
                  RequiresMountsFor = [
                    guestTaskMount
                    guestCredsMount
                  ];
                };
                # The agent's shell inherits this PATH and needs the whole
                # guest toolchain; the supervisor also resolves its helpers
                # from it.
                path = [ "/run/current-system/sw" ];
                serviceConfig = {
                  Type = "exec";
                  User = "root";
                  Group = "root";
                  WorkingDirectory = "/workspace";
                  # The guest never reparses executor fields from the
                  # prompt's front matter; the host stages canonical
                  # task-meta in the read-only credential share.
                  ExecStart = getExe guestSupervisor;
                  # Units do not read /etc/set-environment, so the proxy is
                  # restated. The Bash timeouts let a blocking ask-cockpit
                  # call outlive Claude Code's default tool timeout.
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

              # Workers have no forge credentials, so a local commit is how
              # a patch is captured. The author identity is constant because
              # per-VM values would fork the shared guest closure.
              programs.git = {
                enable = true;
                config = {
                  user.name = "drone";
                  user.email = "drone@agents.invalid";
                };
              };

              # Executors share the workspace but keep private 0700 homes
              # and distinct uids, which blocks ptrace between them.
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

              # Reaching the serial console requires host root, so guest
              # containment does not rest on in-guest auth.
              services.getty.autologinUser = "root";

              system.stateVersion = "26.05";
            };
        };
    in
    {
      # The fleet roster; VM definitions are generated from it.
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

        # The drainer stages only the credential a task selects.
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
        # The guest closure bakes in the Claude executor, so the grant does
        # not depend on the dev-extras home list.
        unfreePackages = singleton "claude-code";

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

        # Share sources must exist before virtiofsd starts. The task
        # exchange is guest-writable; the credential source is root-only.
        systemd.tmpfiles.rules = concatMap (w: [
          "d ${workDir w.name} 0770 root users -"
          "d ${credsDir w.name} 0700 root root -"
        ]) cfg.workers;

        systemd.services = listToAttrs (
          map (
            w:
            # These units are what `fleet health` sums for its memory figure.
            (nameValuePair "microvm@${w.name}" {
              serviceConfig = {
                # The drainer owns lifecycle; Restart=always would fight it.
                Restart = mkForce "no";
                # Volumes are wiped on next start, so a graceful poweroff
                # buys nothing. SIGKILL makes every stop instant and records
                # success rather than a timeout failure, which would trip the
                # OnFailure alert. [ "" ] is how a drop-in clears ExecStop
                # from the shared microvm@ template.
                ExecStop = mkForce [ "" ];
                KillSignal = "SIGKILL";
                # systemd treats only TERM/HUP/INT/PIPE as clean, so this
                # KillSignal must be declared or the stop records as failure.
                SuccessExitStatus = "SIGKILL";
                TimeoutStopSec = mkForce 3;
                # The runner's autoCreate recreates these blank, so deleting
                # them here makes every boot a clean slate.
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
