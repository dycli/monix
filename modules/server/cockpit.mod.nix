# Cockpit: the user's primary interactive agent session. Claude Code over
# tmux/SSH and opencode web are interchangeable frontends to the same seat,
# carrying full user privileges (contrast the locked-down fleet workers of
# agent-vm.mod.nix). Agent tooling itself comes from packages.mod.nix /
# claude.mod.nix, gated on `isDesktop || cockpit.enable`.
#
# MIGRATION IN PROGRESS: the seat is moving from the primary user to the
# dedicated `bridge` account below — full tool permissions inside, walls
# enforced by the OS (no wheel, no Nix trust, no secrets, default-deny
# network). Phase 1 ships the account and its cage; sessions still run as
# the primary user until state migrates.
{ inputs, self, ... }:
{
  flake.homeModules.cockpit =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      guide = import ../../lib/fleet-guide.nix;
      inherit (lib.attrsets) genAttrs;
      inherit (lib.lists) concatMap map;
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
        "ship-costs"
        "ship-costs *"
        # memo (memo.mod.nix) must never prompt, or in-the-moment notes die.
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
        # Standing policy: commit/test freely, push only on explicit word —
        # so stage/commit never prompt, push stays absent.
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
        # Read-only inspection commands. Claude's built-in classifier already
        # auto-approves most; listing them stops OpenCode's static globs
        # prompting on every grep/ls. Anything mutating, network-reaching, or
        # otherwise unsafe (curl, ssh, sed -i, rm, pkill, nix shell/run)
        # stays prompt-bound.
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
        # The paths are already absolute — interpolating them bare keeps the
        # rule a single slash; a doubled slash never matches, silently
        # killing the rule (bit us live: memory writes prompted).
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
      # Claude permits reads within its working directory; OpenCode needs this
      # explicitly or it prompts for ordinary cockpit files like AGENTS.md.
      # Edits stay limited to the canonical paths.
      opencodeReadPermissions = opencodeFilePermissions ++ [
        "${cockpitDir}/**"
        "${lib.strings.removePrefix "/" cockpitDir}/**"
        "${holdDir}/**"
        "${lib.strings.removePrefix "/" holdDir}/**"
      ];
      opencodePermissions = {
        # OpenCode only has static globs (no read-only classifier), so
        # unmatched commands stay prompt-bound rather than broadening this.
        bash = mkOpenCodeRules claudeBashPermissions;
        read = mkOpenCodeRules opencodeReadPermissions;
        edit = mkOpenCodeRules opencodeFilePermissions;
        external_directory = mkOpenCodeRules (map (path: "${path}/**") claudeFilePermissions);
        # Mirror Claude's built-in discovery/delegation tool allowances.
        glob = "allow";
        grep = "allow";
        list = "allow";
        task = "allow";
        # OpenCode can't scope webfetch by domain; keep it stricter than
        # Claude's github.com-only allow.
        webfetch = "ask";
        websearch = "allow";
        todowrite = "allow";
        question = "allow";
        skill = "allow";
      };
      # Restore the restrictions that make Plan non-editing and Explore
      # read-only (appended after OpenCode's built-in agent rules).
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
      # Opt-in per home, NOT derived from the home's path: this aspect serves
      # both seats, and only the fenced one may drop its prompts. Deriving it
      # from `userHome == "/home/bridge"` would silently re-enable prompts (or
      # worse, un-prompt the wrong seat) under the pending cockpit->bridge
      # rename. Set in home-manager.users.bridge below; max never gets it.
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

        # Generated from the Claude cockpit allowlist so policy can't drift
        # by frontend, even though this config is normally mutable state.
        home.file.".config/opencode/opencode.jsonc" = {
          force = true;
          text = toJSON {
            "$schema" = "https://opencode.ai/config.json";
            provider.local = {
              npm = "@ai-sdk/openai-compatible";
              name = "fw0 local inference";
              options = {
                baseURL = "http://127.0.0.1:8091/v1";
                apiKey = "local";
              };
              models = {
                "qwen3.6-35b-a3b" = { };
                "gpt-oss-120b" = { };
              };
            };
            permission = opencodePermissions;
            agent.plan.permission = opencodePlanPermissions;
            agent.explore.permission = opencodeExplorePermissions;
          };
        };

        # ~/cockpit/memory is the real, vendor-neutral directory; Claude's
        # per-project memory path is a symlink into it so every frontend
        # reads/writes the same files.
        home.file.".claude/projects/${projectKey}/memory" = {
          force = true;
          source = config.lib.file.mkOutOfStoreSymlink cockpitMemoryDir;
        };

        # Declarative so the allowlist can't drift from what AGENTS.md
        # promises. The scoped-sudo fleet hop is allowed as one prefix rather
        # than per-subcommand, since the immutable fleet tool is the boundary.
        home.file."cockpit/.claude/settings.json" = {
          force = true;
          text = toJSON {
            permissions = {
              # The allowlist stays meaningful even under bypass: it is what
              # AGENTS.md promises, and the only thing left if the mode is
              # ever dialed back.
              allow = claudeAllow;
              defaultMode = if config.cockpit.bypassPermissions then "bypassPermissions" else "default";
              # `cd ~/ark/monix && …` was the single largest source of
              # prompts; treat the flake repo and projects dir as additional
              # working directories so cd/read stop prompting there. The
              # memory symlink path is outside cwd, so edit rules alone
              # still prompted — it needs working-directory status too.
              additionalDirectories = [
                monixDir
                holdDir
                claudeMemoryDir
              ];
            };
            # Every session starts with part 1 of the memory digest already
            # in context; `|| true` because a refusal (pending compressions)
            # exits 1 but its stdout is still the instruction to surface.
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

  flake.nixosModules.cockpit =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) attrValues;
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption;

      # Fixed uid: the egress fence below is a drop-in on user-<uid>.slice,
      # which must name the uid statically.
      seatUid = 1001;

      topology = import ../../lib/fleet-topology.nix;
      seatProxy = "http://${topology.seatProxyAddr}:${toString topology.seatProxyPort}";
    in
    {
      options.cockpit.enable = mkEnableOption "the persistent cockpit session role on this host";

      options.cockpit.webEnable = mkEnableOption "the opencode web cockpit seat";

      config = mkIf config.cockpit.enable {
        assertions = [
          {
            # The seat is shell-capable and reachable only as ai.<domain>
            # through the ship proxy; without it the unit would run unreachable.
            assertion = config.cockpit.webEnable -> config.shipProxy.enable;
            message = "cockpit.webEnable requires shipProxy.enable (the tailnet-only front door)";
          }
          {
            # The seat account's only network door is the cockpit listener on
            # the fleet's squid; without the fleet the account is network-dead.
            assertion = config.agentFleet.enable;
            message = "the cockpit seat's egress proxy rides the fleet squid (microvm-host.mod.nix)";
          }
        ];

        # THE SEAT ACCOUNT — where the AI will run fully-permissioned. The
        # boundary is what this user CANNOT do: not in wheel, not a trusted
        # Nix user, not an agenix recipient, no push credentials, and fenced
        # by the slice below. Reach it via plain sshd only: a Tailscale SSH
        # session would run under tailscaled's cgroup and bypass the fence.
        users.users.bridge = {
          isNormalUser = true;
          uid = seatUid;
          group = "bridge";
          description = "bridge seat";
          # Group-enterable so the primary user (a bridge group member)
          # can reach the seat's repos and files.
          homeMode = "750";
          openssh.authorizedKeys.keys = self.keys-admin;
          # The system journal is the engineer's debugging sight — reading
          # it is seat work (captain's call 2026-07-29). Read-only: journal
          # mutations still need root.
          extraGroups = singleton "systemd-journal";
        };
        users.groups.bridge.gid = seatUid;

        # THE CAGE — cgroup-eBPF address filter on every process the seat
        # user runs, both directions, all interfaces. The tailnet is covered
        # here precisely because Tailscale ACLs cannot tell fw0's users
        # apart. The only reachable peer is squid's dedicated loopback
        # address; domain policy lives in squid's cockpit ACL
        # (microvm-host.mod.nix). Loopback services on 127.0.0.1 (Matrix,
        # media, HA) stay out of reach.
        systemd.slices."user-${toString seatUid}".sliceConfig = {
          IPAddressDeny = "any";
          IPAddressAllow = singleton "${topology.seatProxyAddr}/32";
        };

        # THE SEAT'S HOME — the same self-gating home aspects as the primary
        # user (desktop aspects skip themselves on a server), plus the proxy
        # environment: every outbound tool inherits the fenced egress door
        # with no per-tool config. Seat state arrives as COPIES of the
        # primary user's — migration is copy-first, and the old seat stays
        # intact until the captain retires it.
        home-manager.users.bridge = {
          imports = attrValues self.homeModules;

          home.username = "bridge";
          home.homeDirectory = "/home/bridge";
          home.stateVersion = config.system.stateVersion;

          # The point of the migration: prompts off inside the cage. Safe
          # only because this account is the fenced one — see the account and
          # slice definitions above for what it cannot do.
          cockpit.bypassPermissions = true;

          home.sessionVariables = {
            HTTP_PROXY = seatProxy;
            HTTPS_PROXY = seatProxy;
            NO_PROXY = "127.0.0.1,localhost";
          };
        };

        # The captain reaches the seat's files through its group.
        users.users.${config.primaryUser}.extraGroups = singleton "bridge";

        # The seat's working directory. Claude Code keys per-project state to
        # this path, so it must exist before the first session.
        systemd.tmpfiles.rules = singleton "d /home/bridge/cockpit 0750 bridge bridge -";

        # tmux is the session's persistence layer; the binary is already
        # system-wide (packages.mod.nix), this adds the /etc config.
        programs.tmux.enable = true;
        programs.tmux.historyLimit = 50000;

        # python3/jq keep everyday data munging off the `nix shell
        # nixpkgs#python3` path, which prompted on every use.
        environment.systemPackages = [
          inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
          pkgs.python3
          pkgs.jq
        ];

        # Runs AS the seat account (needs its auth.json/home/tooling, so not
        # filesystem-sandboxed like a tenant service; NOT in the seat's
        # fenced user slice — the web seat is the sanctioned egress
        # exception, and only root can start system services). Binds
        # seatWebAddr, a loopback address the parser fences don't allow, so
        # a compromised media/immich/frigate service can't drive the seat;
        # nginx (ship-proxy) serves it tailnet-only as ai.<domain>, so
        # reaching the seat means being on the tailnet — same posture as
        # every other ship service, no app-level auth in front.
        systemd.services.opencode-web = mkIf config.cockpit.webEnable {
          description = "opencode web UI cockpit seat";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          # NixOS privilege wrappers must precede the unwrapped packages in
          # the system profile, or sudo finds its non-setuid binary.
          path = [
            "/run/wrappers"
            "/run/current-system/sw"
            "/etc/profiles/per-user/bridge"
          ];
          serviceConfig = {
            User = "bridge";
            Group = "bridge";
            # The web seat gets the SAME door as an interactive one. It is
            # a system service, so the user-1001.slice fence — which
            # covers login sessions — never applied to it. Until this, the
            # squid-only story applied to tmux sessions and not to the seat
            # reachable from a phone. This denies the public internet, the
            # LAN, the tailnet, and the fleet bridge, and routes its HTTP
            # through squid's domain allowlist.
            #
            # What it does NOT do, because systemd IP filtering matches
            # ADDRESSES and not ports: every service bound to 0.0.0.0
            # answers on these addresses too. Verified from inside the
            # interactive seat, which carries the same shape of fence:
            # llama-swap, Immich, SABnzbd and nginx (hence any ship vhost
            # by Host header) are all reachable through the one allowed
            # address. Closing that needs services off 0.0.0.0 or a real
            # network namespace for the seat — see the audit4 backlog. The
            # fence below is still worth having: it is the difference
            # between "the household's own services" and "anywhere on the
            # internet".
            IPAddressAllow = [
              "${topology.seatProxyAddr}/32"
              "${topology.seatIngressAddr}/32"
            ];
            IPAddressDeny = "any";
            # The declaratively generated config (opencode.jsonc above) is
            # the one the seat must run with. The proxy variables are the
            # other half of the fence: home.sessionVariables only reach
            # login shells, so without these the web seat would talk to
            # squid's allowlist not at all.
            Environment = [
              "OPENCODE_CONFIG=/home/bridge/.config/opencode/opencode.jsonc"
              "HTTP_PROXY=${seatProxy}"
              "HTTPS_PROXY=${seatProxy}"
              "NO_PROXY=127.0.0.1,localhost"
            ];
            WorkingDirectory = "/home/bridge/cockpit";
            # The seat's listener is the one socket this service may open;
            # anything else it tries to bind is a bug or a compromise.
            SocketBindAllow = "tcp:${toString topology.seatWebPort}";
            SocketBindDeny = "any";
            # Origin derived from the ship proxy's zone so a domain change
            # can't silently break the seat's CORS.
            ExecStart = "${getExe pkgs.opencode} web --hostname ${topology.seatWebAddr} --port ${toString topology.seatWebPort} --cors https://ai.${config.shipProxy.domain} --print-logs";
            Restart = "always";
            RestartSec = 3;
          };
        };

        # No memory or PID ceiling on the web seat: measured over 4.7 days
        # it peaked at 0.8G against a 64G cap and used 13 PIDs against 8192,
        # so neither limit had ever done anything. See fw0.mod.nix for why
        # the per-tenant ceilings were retired generally.
      };
    };
}
