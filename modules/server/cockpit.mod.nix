# The interactive agent seat. Claude Code over tmux/SSH and opencode web
# are interchangeable frontends to the same account; the tooling itself
# comes from packages.mod.nix and claude.mod.nix.
#
# The seat runs as `bridge`, an account with no wheel, no Nix trust, no
# secrets and default-deny egress, so tool permissions inside it can be
# broad.
{ inputs, self, ... }:
{
  flake.homeModules.default = self.homeModules.cockpit;
  flake.homeModules.cockpit =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      inherit (lib.ship) guide topology;
      inherit (lib.attrsets)
        genAttrs
        listToAttrs
        mapAttrsToList
        nameValuePair
        optionalAttrs
        ;
      inherit (lib.lists) concatLists concatMap map;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption;
      inherit (lib.strings) toJSON;
      # Derive every path from the home this module is applied to, NOT from
      # primaryUser: the same aspect serves both the primary user's seat and
      # the bridge account (home-manager.users.bridge below), each seeing its
      # own repos, working dir, and memory.
      userHome = config.home.homeDirectory;
      monixDir = "${userHome}/ark/monix";
      holdDir = "${userHome}/hold";
      cockpitDir = "${userHome}/cockpit";
      cockpitMemoryDir = "${userHome}/cockpit/memory";
      # Claude Code keys per-project state to the working dir path with
      # slashes turned into dashes ("/home/max/cockpit" -> -home-max-cockpit).
      projectKey = lib.strings.replaceStrings [ "/" ] [ "-" ] cockpitDir;
      claudeMemoryDir = "${userHome}/.claude/projects/${projectKey}/memory";
      # Claude's cockpit policy is canonical; rendered into both
      # frontend-specific formats below.
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
      gitReadPermissions = concatMap (command: [
        "git ${command}"
        "git -C * ${command}"
      ]) gitReadCommands;
      claudeBashPermissions = [
        "sudo -n -u fleet-operator fleet *"
        "fleet dispatch *"
        # memo must never prompt, or notes are lost mid-thought.
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
        # Commit freely, push only on request: no push rule here.
        "git -C ${monixDir} add *"
        "git -C ${monixDir} commit *"
        # journalctl mutations require root; systemctl gets only read verbs.
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
        # Listed for OpenCode, which has only static globs where Claude has
        # a read-only classifier.
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
        # These paths are absolute; a doubled slash never matches and
        # silently disables the rule.
        ++ concatMap (path: [
          "Read(${path}/**)"
          "Edit(${path}/**)"
          "Write(${path}/**)"
        ]) claudeFilePermissions
        ++ [
          "WebFetch(domain:github.com)"
          "WebSearch"
          "SendUserFile"
        ];
      # OpenCode evaluates the final matching rule; keep the catch-all first.
      mkOpenCodeRules = patterns: { "*" = "ask"; } // genAttrs patterns (_: "allow");
      # OpenCode strips the leading slash for file-tool paths, but
      # external_directory checks the same path in absolute form.
      opencodeFilePermissions = concatMap (path: [
        "${path}/**"
        "${lib.strings.removePrefix "/" path}/**"
      ]) claudeFilePermissions;
      # Claude permits reads inside its working directory; OpenCode needs
      # them listed. Edits stay limited to the canonical paths.
      opencodeReadPermissions = opencodeFilePermissions ++ [
        "${cockpitDir}/**"
        "${lib.strings.removePrefix "/" cockpitDir}/**"
        "${holdDir}/**"
        "${lib.strings.removePrefix "/" holdDir}/**"
      ];
      opencodePermissions = {
        # Unmatched commands stay prompt-bound.
        bash = mkOpenCodeRules claudeBashPermissions;
        read = mkOpenCodeRules opencodeReadPermissions;
        edit = mkOpenCodeRules opencodeFilePermissions;
        external_directory = mkOpenCodeRules (map (path: "${path}/**") claudeFilePermissions);
        # Mirrors Claude's built-in discovery and delegation allowances.
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
      # Appended after OpenCode's built-in agent rules, restoring the
      # non-editing Plan and read-only Explore behaviour.
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
      # Opt-in per home rather than derived from the home's path, so a
      # rename cannot silently move it to the wrong account.
      options.cockpit.bypassPermissions = mkEnableOption ''
        running this seat with Claude tool prompts off. Only ever true for a
        home whose account is fenced at the OS (no wheel, no Nix trust, no
        secrets, default-deny egress) — the walls replace the prompts
      '';

      config = mkIf osConfig.cockpit.enable {
        home.file."cockpit/AGENTS.md" = {
          force = true;
          text = guide.system + guide.pilot;
        };
        home.file."cockpit/CLAUDE.md" = {
          force = true;
          text = "@AGENTS.md\n";
        };

        # Generated from the Claude allowlist and the served inference
        # catalog so the frontends cannot drift apart, though this file is
        # normally mutable state. The baseURL is the seat-plane address:
        # the seat fences admit that /32, not 127.0.0.1 (see the slice
        # fence below).
        home.file.".config/opencode/opencode.jsonc" = {
          force = true;
          text = toJSON (
            {
              "$schema" = "https://opencode.ai/config.json";
              permission = opencodePermissions;
              agent.plan.permission = opencodePlanPermissions;
              agent.explore.permission = opencodeExplorePermissions;
            }
            // optionalAttrs osConfig.inference.enable {
              provider.local = {
                npm = "@ai-sdk/openai-compatible";
                name = "fw0 local inference";
                options = {
                  baseURL = "http://${topology.seatInferenceAddr}:${toString osConfig.inference.port}/v1";
                  apiKey = "local";
                };
                models = listToAttrs (
                  concatLists (
                    mapAttrsToList (n: m: map (id: nameValuePair id { }) ([ n ] ++ m.aliases)) osConfig.inference.models
                  )
                );
              };
            }
          );
        };

        # Claude's per-project memory path is a symlink into
        # ~/cockpit/memory so every frontend shares one set of files.
        home.file.".claude/projects/${projectKey}/memory" = {
          force = true;
          source = config.lib.file.mkOutOfStoreSymlink cockpitMemoryDir;
        };

        # The scoped-sudo fleet hop is allowed as one prefix rather than
        # per-subcommand; the fleet tool itself is the boundary.
        home.file."cockpit/.claude/settings.json" = {
          force = true;
          text = toJSON {
            permissions = {
              allow = claudeAllow;
              defaultMode = if config.cockpit.bypassPermissions then "bypassPermissions" else "default";
              # The memory symlink resolves outside the working directory,
              # so edit rules alone are not enough; it needs
              # working-directory status.
              additionalDirectories = [
                monixDir
                holdDir
                claudeMemoryDir
              ];
            };
            # `|| true` because a refusal for pending compressions exits 1
            # while still printing the instruction to surface.
            hooks.SessionStart = [
              {
                hooks = [
                  {
                    type = "command";
                    command = "memo wake 2>&1 || true";
                  }
                ];
              }
            ];
          };
        };
      };
    };

  flake.nixosModules.default = self.nixosModules.cockpit;

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
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption;

      # Fixed uid: the fence below is a drop-in on user-<uid>.slice, which
      # must name the uid statically.
      seatUid = 1001;

      inherit (lib.ship) topology fences;
    in
    {
      options.cockpit.enable = mkEnableOption "the persistent cockpit session role on this host";

      options.cockpit.webEnable = mkEnableOption "the opencode web cockpit seat";

      config = mkIf config.cockpit.enable {
        assertions = [
          {
            # The seat is only reachable as ai.<domain> through the proxy.
            assertion = config.cockpit.webEnable -> config.shipProxy.enable;
            message = "cockpit.webEnable requires shipProxy.enable (the tailnet-only front door)";
          }
          {
            # squid, the seat's only network door, comes with the fleet.
            assertion = config.agentFleet.enable;
            message = "the cockpit seat's egress proxy rides the fleet squid (microvm-host.mod.nix)";
          }
        ];

        # Not in wheel, not a trusted Nix user, not an agenix recipient, no
        # push credentials, fenced by the slice below. A Tailscale SSH
        # session would run under tailscaled's cgroup and bypass that fence.
        users.users.bridge = {
          isNormalUser = true;
          uid = seatUid;
          group = "bridge";
          description = "bridge seat";
          # Group-enterable so the primary user can reach the seat's files.
          homeMode = "750";
          openssh.authorizedKeys.keys = self.keys-admin;
          # Journal read access; mutations still require root. users for
          # write access to the model directory.
          extraGroups = [
            "systemd-journal"
            "users"
          ];
        };
        users.groups.bridge.gid = seatUid;

        # Address filter on every process this user runs, both directions,
        # all interfaces — including the tailnet, which Tailscale ACLs
        # cannot restrict per-user. The public internet is unmatched and so
        # allowed; the LAN, the tailnet, the fleet bridge and the loopback
        # services are denied. resolved's stub is allowed for DNS, and
        # llama-swap through its dedicated seat-plane address — filtering
        # is port-blind, so admitting 127.0.0.1 itself would open every
        # loopback service (the cameras and the Minecraft console carry no
        # auth of their own).
        #
        # There is deliberately no domain allowlist. The model API has to be
        # reachable, so anything the seat can read it can also send, and the
        # Nix daemon fetches arbitrary URLs on its behalf regardless.
        systemd.slices."user-${toString seatUid}".sliceConfig = {
          IPAddressAllow = [
            "127.0.0.53/32"
            "${topology.seatInferenceAddr}/32"
          ];
          IPAddressDeny = fences.internetOnlyDeny ++ [ "127.0.0.0/8" ];
        };

        # Home aspects arrive via home-manager.sharedModules from the
        # bundles this host imports, same as the primary user.
        home-manager.users.bridge = {
          home.username = "bridge";
          home.homeDirectory = "/home/bridge";
          home.stateVersion = config.system.stateVersion;

          # Safe only because this account is the fenced one.
          cockpit.bypassPermissions = true;
        };

        users.users.${config.primaryUser}.extraGroups = singleton "bridge";

        # Claude Code keys per-project state to this path, so it must exist
        # before the first session.
        systemd.tmpfiles.rules = singleton "d /home/bridge/cockpit 0750 bridge bridge -";

        # The binary is already system-wide; this adds the /etc config.
        programs.tmux.enable = true;
        programs.tmux.historyLimit = 50000;

        # Kept here so routine data munging does not need `nix shell`.
        environment.systemPackages = [
          inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
          pkgs.python3
          pkgs.jq
        ];

        # Runs as the seat account for its home and credentials, so it is
        # not filesystem-sandboxed. Being a system service it sits outside
        # the seat's user slice and carries its own fence below. It binds
        # seatWebAddr, which the parser fences do not allow, and nginx
        # serves it as ai.<domain> with no application auth.
        systemd.services.opencode-web = mkIf config.cockpit.webEnable {
          description = "opencode web UI cockpit seat";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
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
            # The same reach as an interactive seat, plus the address nginx
            # proxies from. systemd filters addresses and not ports, so any
            # service bound to 0.0.0.0 still answers on what is allowed here.
            IPAddressAllow = [
              "${topology.seatIngressAddr}/32"
              "${topology.seatInferenceAddr}/32"
            ];
            IPAddressDeny = fences.internetOnlyDeny ++ [ "127.0.0.0/8" ];
            Environment = singleton "OPENCODE_CONFIG=/home/bridge/.config/opencode/opencode.jsonc";
            WorkingDirectory = "/home/bridge/cockpit";
            # The seat's listener is the one socket this service may open;
            # anything else it tries to bind is a bug or a compromise.
            SocketBindAllow = "tcp:${toString topology.seatWebPort}";
            SocketBindDeny = "any";
            # CORS origin follows the proxy's zone so a domain change
            # cannot silently break it.
            ExecStart = "${getExe pkgs.opencode} web --hostname ${topology.seatWebAddr} --port ${toString topology.seatWebPort} --cors https://ai.${config.shipProxy.domain} --print-logs";
            Restart = "always";
            RestartSec = 3;
          };
        };
      };
    };
}
