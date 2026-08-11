# Agent-fleet worker guests: minimal NixOS microVMs with no tailnet, no
# monorepo and no host secrets, reachable only through the squid allowlist.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.agent-guests;
  flake.nixosModules.agent-guests =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets)
        genAttrs
        listToAttrs
        nameValuePair
        ;
      inherit (lib.lists) concatMap singleton;
      inherit (lib.meta) getExe getExe';
      inherit (lib.modules) mkForce;
      inherit (lib.options) mkOption;
      inherit (lib.strings)
        concatMapStringsSep
        fixedWidthString
        hasSuffix
        toJSON
        ;
      inherit (lib) types;

      inherit (lib.ship) guide;
      hintFile = pkgs.writeText "worker-hint.md" (guide.system + guide.worker);

      cfg = config.agentFleet;

      inherit (lib.ship) topology;
      inherit (topology) hostAddr;
      proxyUrl = "http://${hostAddr}:3128";
      # Local inference is plain HTTP to a bridge IP, which a CONNECT
      # allowlist cannot express, so it bypasses the proxy.
      noProxy = "127.0.0.1,localhost,${hostAddr}";

      # The ai-sdk loader requires a non-empty apiKey; llama-swap ignores it.
      opencodeConfig = pkgs.writeText "opencode.json" (
        toJSON (
          {
            "$schema" = "https://opencode.ai/config.json";
          }
          // {
            provider.local = {
              npm = "@ai-sdk/openai-compatible";
              name = "ship-local inference (llama-swap)";
              options = {
                baseURL = "http://${hostAddr}:${toString config.inference.port}/v1";
                apiKey = "local";
              };
              models = genAttrs config.inference.modelIds (_: { });
            };
          }
        )
      );

      credsDir = name: "/run/agents/creds/${name}";
      guestCredsMount = "/run/host-creds";

      # virtiofs passes uid/gid verbatim, so the in-guest executor reaches this
      # share through the agent-guest gid, pinned to the same value on host
      # and guest. A broader group (users) would let the seat write into live
      # exchanges.
      agentGuestGid = 3000;
      workDir = name: "/var/lib/agents/work/${name}/task";
      guestTaskMount = "/run/task";

      # Per-worker volume images, wiped on every VM start.
      volumes = [
        {
          image = "nix-overlay.img";
          mountPoint = "/nix/.rw-store";
          size = 8192;
        }
        {
          image = "workspace.img";
          mountPoint = "/workspace";
          size = 20480;
        }
      ];

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
          # The resident drainer owns VM lifecycle.
          autostart = false;

          config =
            { pkgs, ... }:
            let
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

              # agent-local has no credential, so the source is guarded.
              opencodeExecutor = pkgs.writeShellApplication {
                name = "agent-opencode-exec";
                text = ''
                  # shellcheck disable=SC1091
                  [ ! -r /run/agent-opencode/env ] || . /run/agent-opencode/env
                  exec ${getExe pkgs.opencode} "$@"
                '';
              };

              guestSupervisor = pkgs.rustPlatform.buildRustPackage {
                pname = "fleet-guest-supervisor";
                version = "0.1.0";
                src = lib.sources.cleanSourceWith {
                  src = ./agent-vm;
                  filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
                };

                cargoLock.lockFile = ./agent-vm/Cargo.lock;
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

                # vsock context ids must be >= 3.
                vsock.cid = 100 + index;

                interfaces = singleton {
                  type = "tap";
                  id = "vm-${name}"; # br-agents enslaves taps by a vm-* networkd match
                  inherit mac;
                };

                # Not a virtiofs share of the live store: host gc and
                # nix-optimise mutate inodes underneath virtiofsd and corrupt
                # running guests.
                storeOnDisk = true;

                # Identity travels outside the closure so the fleet boots one
                # store image.
                kernelParams = [
                  "drone.name=${name}"
                  "drone.addr=${addr}/24"
                ];

                shares = [
                  # Empty while idle; the drainer stages one credential per task.
                  {
                    proto = "virtiofs";
                    tag = "creds";
                    source = credsDir name;
                    mountPoint = guestCredsMount;
                    readOnly = true;
                    cache = "never";
                  }
                  {
                    proto = "virtiofs";
                    tag = "task";
                    source = workDir name;
                    mountPoint = guestTaskMount;
                    # Default caching keeps a stale negative dentry, so a
                    # running guest never sees prompt.md appear.
                    cache = "never";
                  }
                ];

                writableStoreOverlay = "/nix/.rw-store";
                inherit volumes;
              };

              # No gateway and no DNS: the guest cannot route or resolve.
              # The address is assigned but not enforced, since nothing pins a
              # tap to its MAC.
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
                pkgs.sqlite
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
              # cache.nixos.org is the only substituter on the egress allowlist.

              # Type=exec rather than oneshot: a oneshot's start job would last
              # the whole task and hold the host's `systemctl start` to its
              # timeout.
              systemd.services.agent-task = {
                description = "Run the dispatched task";
                wantedBy = [ "multi-user.target" ];
                unitConfig = {
                  # No ConditionPathExists on prompt.md: the guest boots idle
                  # and the supervisor blocks for a task.
                  RequiresMountsFor = [
                    guestTaskMount
                    guestCredsMount
                  ];
                };
                # The agent's shell and the supervisor's helpers resolve here.
                path = [ "/run/current-system/sw" ];
                serviceConfig = {
                  Type = "exec";
                  User = "root";
                  Group = "root";
                  WorkingDirectory = "/workspace";
                  # Executor selection comes from task-meta in the read-only
                  # credential share, never from the prompt.
                  ExecStart = getExe guestSupervisor;
                  # Units do not read /etc/set-environment, so the proxy is
                  # restated. The Bash timeouts let a blocking ask-cockpit call
                  # outlive the executor's default tool timeout.
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
                  LimitFSIZE = cfg.taskExchangeMaxBytes;
                };
              };

              # A constant identity: per-VM values would fork the shared
              # guest closure.
              programs.git = {
                enable = true;
                config = {
                  user.name = "drone";
                  user.email = "drone@agents.invalid";
                };
              };

              # Executors share the workspace but keep private 0700 homes and
              # distinct uids, which blocks ptrace between them. agent-guest
              # (runuser grants supplementary groups) carries the task
              # exchange across virtiofs.
              users.groups.agent-guest.gid = agentGuestGid;
              users.users = {
                agent-claude = {
                  isNormalUser = true;
                  homeMode = "0700";
                  extraGroups = [ "agent-guest" ];
                  description = "Claude fleet executor";
                };
                agent-codex = {
                  isNormalUser = true;
                  homeMode = "0700";
                  extraGroups = [ "agent-guest" ];
                  description = "Codex fleet executor";
                };
                agent-opencode = {
                  isNormalUser = true;
                  homeMode = "0700";
                  extraGroups = [ "agent-guest" ];
                  description = "opencode fleet executor";
                };
                agent-local = {
                  isNormalUser = true;
                  homeMode = "0700";
                  extraGroups = [ "agent-guest" ];
                  description = "credentialless local-model fleet executor";
                };
              };
              systemd.tmpfiles.rules = singleton "d /workspace 0770 root users -";

              # The serial console requires host root to reach.
              services.getty.autologinUser = "root";

              system.stateVersion = "26.05";
            };
        };
    in
    {
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

      config = {
        assertions = [
          {
            assertion =
              lib.lists.length cfg.workers == (
                cfg.workers
                |> map (w: w.name)
                |> lib.lists.unique
                |> lib.lists.length
              );
            message = "agentFleet worker names must be unique";
          }
          {
            assertion =
              lib.lists.length cfg.workers == (
                cfg.workers
                |> map (w: w.index)
                |> lib.lists.unique
                |> lib.lists.length
              );
            message = "agentFleet worker indices must be unique";
          }
        ];

        microvm.vms = listToAttrs (map (w: nameValuePair w.name (mkAgentGuest w)) cfg.workers);

        # Share sources must exist before virtiofsd starts.
        users.groups.agent-guest.gid = agentGuestGid;
        systemd.tmpfiles.rules = concatMap (w: [
          "d ${workDir w.name} 0770 root agent-guest -"
          "d ${credsDir w.name} 0700 root root -"
        ]) cfg.workers;

        systemd.services = listToAttrs (
          map (
            w:
            (nameValuePair "microvm@${w.name}" {
              serviceConfig = {
                # The drainer owns lifecycle; Restart=always would fight it.
                Restart = mkForce "no";
                # Volumes are wiped on next start, so a graceful poweroff buys
                # nothing. [ "" ] clears ExecStop from the microvm@ template.
                ExecStop = mkForce [ "" ];
                KillSignal = "SIGKILL";
                # systemd treats only TERM/HUP/INT/PIPE as clean, so an
                # undeclared SIGKILL would record the stop as a failure.
                SuccessExitStatus = "SIGKILL";
                TimeoutStopSec = mkForce 3;
                # The runner's autoCreate recreates these blank.
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
