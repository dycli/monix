# The interactive agent seat: Claude Code over tmux/SSH and opencode web as
# interchangeable frontends to one fenced `bridge` account.
{ inputs, self, ... }:
{
  flake.homeModules.lab = self.homeModules.cockpit;
  flake.homeModules.cockpit =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      inherit (lib.ship) guide topology;
      inherit (lib.attrsets) genAttrs;
      inherit (lib.lists) concatMap map singleton;
      inherit (lib.options) mkEnableOption;
      inherit (lib.strings) toJSON;
      # Paths derive from the home this module is applied to, not from
      # primaryUser: the same aspect serves both accounts, each with its own
      # repos, working dir and memory.
      userHome = config.home.homeDirectory;
      monixDir = "${userHome}/ark/monix";
      holdDir = "${userHome}/hold";
      cockpitDir = "${userHome}/cockpit";
      cockpitMemoryDir = "${userHome}/cockpit/memory";
      # Claude Code keys per-project state to the working dir path with
      # slashes turned into dashes ("/home/max/cockpit" -> -home-max-cockpit).
      projectKey = lib.strings.replaceStrings (singleton "/") (singleton "-") cockpitDir;
      claudeMemoryDir = "${userHome}/.claude/projects/${projectKey}/memory";
      gitReadCommands = [
        "status*"
        "diff*"
        "log*"
        "show*"
        "blame*"
        "rev-parse*"
        "merge-base*"
        "ls-files*"
        "ls-tree*"
        "cat-file*"
        "branch --show-current*"
        "remote -v"
        "tag --list*"
      ];
      gitReadPermissions =
        gitReadCommands
        |> concatMap (command: [
          "git ${command}"
          "git -C * ${command}"
        ]);
      claudeBashPermissions = [
        "sudo -n -u fleet-operator fleet *"
        "fleet dispatch *"
        # memo must never prompt.
        "memo"
        "memo *"
        "nix build *"
        "nix eval *"
        "nix flake *"
        "nix run nixpkgs#shellcheck *"
        "nix search *"
        "tailscale status*"
      ]
      ++ gitReadPermissions
      ++ [
        # No push rule: pushing is never unattended.
        "git -C ${monixDir} add *"
        "git -C ${monixDir} commit *"
        "journalctl*"
        "systemctl status*"
        "systemctl show*"
        "systemctl cat*"
        "systemctl list-units*"
        "systemctl list-timers*"
        "systemctl list-unit-files*"
        "systemctl list-dependencies*"
        "systemctl is-active*"
        "systemctl is-enabled*"
        "systemctl is-failed*"
        "systemctl --failed*"
        "systemctl --user status*"
        "systemctl --user show*"
        "systemctl --user cat*"
        "systemctl --user is-active*"
        "systemctl --user list-units*"
        "systemctl --user list-timers*"
      ]
      ++ [
        # Listed for OpenCode, which has only static globs where Claude has a
        # read-only classifier.
        "echo *"
        "grep *"
        "rg *"
        "ls"
        "ls *"
        "head *"
        "tail *"
        "wc *"
        "stat *"
        "du *"
        "df"
        "df *"
        "file *"
        "readlink *"
        "realpath *"
        "command -v *"
        "pgrep *"
        "tree *"
        "sleep *"
        "mkdir -p *"
      ];
      claudeFilePermissions = [
        monixDir
        cockpitMemoryDir
        claudeMemoryDir
      ];
      claudeAllow =
        map (command: "Bash(${command})") claudeBashPermissions
        # These paths are absolute; a doubled slash matches nothing and
        # silently disables the rule.
        ++ (
          claudeFilePermissions
          |> concatMap (path: [
            "Read(${path}/**)"
            "Edit(${path}/**)"
            "Write(${path}/**)"
          ])
        )
        ++ [
          "WebFetch(domain:github.com)"
          "WebSearch"
          "SendUserFile"
        ];
      # OpenCode evaluates the final matching rule; keep the catch-all first.
      mkOpenCodeRules = patterns: { "*" = "ask"; } // genAttrs patterns (_: "allow");
      # OpenCode strips the leading slash for file-tool paths, but
      # external_directory checks the same path in absolute form.
      opencodeFilePermissions =
        claudeFilePermissions
        |> concatMap (path: [
          "${path}/**"
          "${lib.strings.removePrefix "/" path}/**"
        ]);
      # Claude permits reads inside its working directory; OpenCode needs them
      # listed.
      opencodeReadPermissions = opencodeFilePermissions ++ [
        "${cockpitDir}/**"
        "${lib.strings.removePrefix "/" cockpitDir}/**"
        "${holdDir}/**"
        "${lib.strings.removePrefix "/" holdDir}/**"
      ];
      opencodePermissions = {
        bash = mkOpenCodeRules claudeBashPermissions;
        read = mkOpenCodeRules opencodeReadPermissions;
        edit = mkOpenCodeRules opencodeFilePermissions;
        external_directory = mkOpenCodeRules (map (path: "${path}/**") claudeFilePermissions);
        glob = "allow";
        grep = "allow";
        list = "allow";
        task = "allow";
        # OpenCode cannot scope webfetch by domain.
        webfetch = "ask";
        websearch = "allow";
        todowrite = "allow";
        question = "allow";
        skill = "allow";
      };
      # Appended after OpenCode's built-in agent rules.
      opencodePlanPermissions = opencodePermissions // {
        edit = "deny";
        task = {
          "*" = "allow";
          general = "deny";
        };
      };
      opencodeExplorePermissions = {
        "*" = "deny";
        inherit (opencodePermissions)
          bash
          external_directory
          glob
          grep
          list
          read
          webfetch
          websearch
          ;
      };
    in
    {
      # Opt-in per home rather than derived from the home's path, so a rename
      # cannot silently move it to the wrong account.
      options.cockpit.bypassPermissions = mkEnableOption ''
        running this seat with Claude tool prompts off. Only ever true for a
        home whose account is fenced at the OS (no wheel, no Nix trust, no
        secrets, default-deny egress) — the walls replace the prompts
      '';

      config = {
        home.file."cockpit/AGENTS.md" = {
          force = true;
          text = guide.system + guide.pilot;
        };
        home.file."cockpit/CLAUDE.md" = {
          force = true;
          text = "@AGENTS.md\n";
        };

        # The baseURL uses the seat-plane address because the slice fence
        # below admits that /32, not 127.0.0.1.
        home.file.".config/opencode/opencode.jsonc" = {
          force = true;
          text = toJSON (
            {
              "$schema" = "https://opencode.ai/config.json";
              permission = opencodePermissions;
              agent.plan.permission = opencodePlanPermissions;
              agent.explore.permission = opencodeExplorePermissions;
            }
            // {
              provider.local = {
                npm = "@ai-sdk/openai-compatible";
                name = "water local inference";
                options = {
                  baseURL = "http://${topology.seatInferenceAddr}:${toString osConfig.inference.port}/v1";
                  apiKey = "local";
                };
                models = genAttrs osConfig.inference.modelIds (_: { });
              };
            }
          );
        };

        # Symlinked so every frontend shares one set of memory files.
        home.file.".claude/projects/${projectKey}/memory" = {
          force = true;
          source = config.lib.file.mkOutOfStoreSymlink cockpitMemoryDir;
        };

        home.file."cockpit/.claude/settings.json" = {
          force = true;
          text = toJSON {
            permissions = {
              allow = claudeAllow;
              defaultMode = if config.cockpit.bypassPermissions then "bypassPermissions" else "default";
              # The memory symlink resolves outside the working directory.
              additionalDirectories = [
                monixDir
                holdDir
                claudeMemoryDir
              ];
            };
            # `|| true`: a pending compression exits 1 while still printing
            # the instruction that must surface.
            hooks.SessionStart = singleton {
              hooks = singleton {
                type = "command";
                command = "memo wake 2>&1 || true";
              };
            };
          };
        };
      };
    };

  flake.nixosModules.lab = self.nixosModules.cockpit;

  flake.nixosModules.cockpit =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;

      # Fixed uid: the fence below is a drop-in on user-<uid>.slice.
      seatUid = 1001;

      inherit (lib.ship) topology fences;
    in
    {
      config = {
        # No wheel, no Nix trust, no secrets. A Tailscale SSH session would
        # run under tailscaled's cgroup and bypass the slice fence below.
        users.users.bridge = {
          isNormalUser = true;
          uid = seatUid;
          group = "bridge";
          description = "bridge seat";
          # Group-enterable so the primary user can reach the seat's files.
          homeMode = "750";
          openssh.authorizedKeys.keys = lib.ship.keys.admin;
          # journal reads; models grants writes to the model directory.
          extraGroups = [
            "systemd-journal"
            "models"
          ];
        };
        users.groups.bridge.gid = seatUid;

        # Address filter on every process this user runs, both directions and
        # all interfaces, including the tailnet, which Tailscale ACLs cannot
        # restrict per-user. Filtering is port-blind, so admitting 127.0.0.1
        # would expose every loopback service; llama-swap gets a dedicated
        # seat-plane address instead.
        systemd.slices."user-${toString seatUid}".sliceConfig = {
          IPAddressAllow = [
            "127.0.0.53/32"
            "${topology.seatInferenceAddr}/32"
          ];
          IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
        };

        home-manager.users.bridge = {
          home.username = "bridge";
          home.homeDirectory = "/home/bridge";
          home.stateVersion = config.system.stateVersion;

          # Safe only because this account is the fenced one.
          cockpit.bypassPermissions = true;
        };

        users.users.${config.primaryUser}.extraGroups = singleton "bridge";

        # Must exist before the first session keys its project state to it.
        systemd.tmpfiles.rules = singleton "d /home/bridge/cockpit 0750 bridge bridge -";

        programs.tmux.enable = true;
        programs.tmux.historyLimit = 50000;
        # terminal-features asserts OSC 52 support even when TERM's terminfo
        # does not advertise Ms.
        programs.tmux.extraConfig = ''
          set -g set-clipboard on
          set -as terminal-features ',*:clipboard'
        '';

        environment.systemPackages = [
          inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
          pkgs.python3
          pkgs.jq
        ];

        # A system service, so it sits outside the seat's user slice and
        # carries its own fence. nginx serves it with no application auth.
        systemd.services.opencode-web = {
          description = "opencode web UI cockpit seat";
          wantedBy = singleton "multi-user.target";
          wants = singleton "network-online.target";
          after = singleton "network-online.target";
          # Privilege wrappers must precede the system profile, or sudo
          # resolves to its non-setuid binary.
          path = [
            "/run/wrappers"
            "/run/current-system/sw"
            "/etc/profiles/per-user/bridge"
          ];
          serviceConfig = {
            User = "bridge";
            Group = "bridge";
            # systemd filters addresses and not ports, so any service bound to
            # 0.0.0.0 still answers on whatever is allowed here.
            IPAddressAllow = [
              "${topology.seatIngressAddr}/32"
              "${topology.seatInferenceAddr}/32"
            ];
            IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
            Environment = singleton "OPENCODE_CONFIG=/home/bridge/.config/opencode/opencode.jsonc";
            WorkingDirectory = "/home/bridge/cockpit";
            # The seat listener is the only socket this service may open.
            SocketBindAllow = "tcp:${toString topology.seatWebPort}";
            SocketBindDeny = "any";
            ExecStart = "${getExe pkgs.opencode} web --hostname ${topology.seatWebAddr} --port ${toString topology.seatWebPort} --cors https://ai.${config.shipProxy.domain} --print-logs";
            Restart = "always";
            RestartSec = 3;
          };
        };
      };
    };
}
