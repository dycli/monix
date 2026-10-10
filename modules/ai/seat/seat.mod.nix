# The AI seat: one fenced, unprivileged account where Claude Code, Codex and
# OpenCode share the ship guide, the project state and hippo. Its home is
# composed here; the primary user's agent CLIs come from `dev` instead.
{
  inputs,
  lib,
  self,
  ...
}:
let
  # A headless Brave on the seat's own host, plus the desktops whose visible
  # Brave the seat drives over HTTP on the tailnet (browser.mod.nix); each
  # desktop admits Water alone at that door.
  browserServers =
    topology:
    {
      browser = {
        command = "/run/current-system/sw/bin/kestrel-browser-headless";
        args = [ ];
      };
    }
    // (
      topology.desktops
      |> lib.attrsets.mapAttrs (
        host: _: {
          url = "http://${host}.${topology.tailnetDomain}:${toString topology.browserPort}/mcp";
        }
      )
    );
in
{
  flake.homeModules.cockpit =
    {
      config,
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.ship) guide opencode topology;
      inherit (lib.attrsets) genAttrs mapAttrs;
      inherit (lib.lists) concatMap map singleton;
      inherit (lib.modules) mkForce;
      inherit (lib.strings) removePrefix toJSON;

      userHome = config.home.homeDirectory;
      monixDir = "${userHome}/ark/monix";
      holdDir = "${userHome}/hold";
      cockpitDir = "${userHome}/cockpit";

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

      # OpenCode has only static globs where Claude has a read-only
      # classifier, so this list exists for OpenCode alone.
      bashAllow = [
        "sudo -n -u ${topology.operator} fleet *"
        "fleet dispatch *"
        # hippo must never prompt.
        "hippo"
        "hippo *"
        "nix build *"
        "nix eval *"
        "nix flake *"
        "nix run nixpkgs#shellcheck *"
        "nix search *"
        "tailscale status*"
      ]
      ++ concatMap (command: [
        "git ${command}"
        "git -C * ${command}"
      ]) gitReadCommands
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

      writableDirs = [
        monixDir
      ];

      # OpenCode strips the leading slash for file-tool paths, but
      # external_directory checks the same path in absolute form.
      bothForms = concatMap (path: [
        "${path}/**"
        "${removePrefix "/" path}/**"
      ]);

      # OpenCode evaluates the final matching rule; keep the catch-all first.
      allowOnly = patterns: { "*" = "ask"; } // genAttrs patterns (_: "allow");

      permission = {
        bash = allowOnly bashAllow;
        # Claude permits reads inside its working directory; OpenCode needs
        # them listed.
        read = allowOnly (
          bothForms (
            writableDirs
            ++ [
              cockpitDir
              holdDir
            ]
          )
        );
        edit = allowOnly (bothForms writableDirs);
        external_directory = allowOnly (map (path: "${path}/**") writableDirs);
        glob = "allow";
        grep = "allow";
        list = "allow";
        task = "allow";
        # OpenCode cannot scope webfetch by domain.
        webfetch = "ask";
        todowrite = "allow";
        question = "allow";
        skill = "allow";
      }
      // opencode.permissions;
    in
    {
      home.sessionVariables = opencode.environment;

      home.file.".config/agents/AGENTS.md".text = mkForce (guide.system + guide.pilot);
      home.file."cockpit/FLEET.md" = {
        force = true;
        text = guide.fleet;
      };

      # The baseURL uses the seat-plane address because the slice fence
      # admits that /32, not 127.0.0.1.
      home.file.".config/opencode/opencode.jsonc" = {
        force = true;
        text = toJSON (
          opencode.config {
            name = "water local inference";
            baseURL = "http://${topology.seatInferenceAddr}:${toString osConfig.inference.port}/v1";
            models = osConfig.inference.openCodeModels;
            extraMcp =
              browserServers topology
              |> mapAttrs (
                _: server:
                if server ? url then
                  {
                    type = "remote";
                    inherit (server) url;
                    enabled = true;
                  }
                else
                  {
                    type = "local";
                    command = singleton server.command ++ server.args;
                    enabled = true;
                  }
              );
            inherit permission;
            # Appended after OpenCode's built-in agent rules.
            agent.plan.permission = permission // {
              edit = "deny";
              task = {
                "*" = "allow";
                general = "deny";
              };
            };
            agent.explore.permission = {
              "*" = "deny";
              inherit (permission)
                bash
                external_directory
                glob
                grep
                list
                read
                webfetch
                ;
            }
            // opencode.permissions;
          }
        );
      };
    };

  flake.nixosModules.lab = self.nixosModules.seat;
  flake.nixosModules.seat =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) attrValues mapAttrs;
      inherit (lib.lists) singleton;
      inherit (lib.strings) toJSON;
      inherit (lib.ship) fences topology;
      inherit (topology) seat;

      json = pkgs.formats.json { };
      toml = pkgs.formats.toml { };
      cfg = config.seat;
    in
    {
      # Host-wide settings of the seat's agent CLIs, which several modules
      # contribute to.
      options.seat = {
        claudeSettings = lib.options.mkOption {
          inherit (json) type;
          default = { };
          description = "Claude Code managed settings, for every launcher.";
        };
        codexConfig = lib.options.mkOption {
          inherit (toml) type;
          default = { };
          description = "Codex's system config layer.";
        };
      };

      config = {
        # No wheel, no Nix trust, and no host/service secrets; its sole
        # provider key is part of the model boundary. A Tailscale SSH session
        # would run under tailscaled's cgroup and bypass the slice fence below.
        users.users.${seat.user} = {
          isNormalUser = true;
          inherit (seat) uid home;
          group = seat.user;
          description = "AI seat";
          # Group-enterable so the primary user can reach the seat's files.
          homeMode = "750";
          openssh.authorizedKeys.keys = lib.ship.keys.admin;
          # journal reads; models grants writes to the model directory.
          extraGroups = [
            "systemd-journal"
            "models"
            "opencode-auth"
          ];
        };
        users.groups.${seat.user}.gid = seat.uid;

        users.users.${config.primaryUser}.extraGroups = singleton seat.user;

        home-manager.users.${seat.user} = {
          imports = [
            self.homeModules.default
            self.homeModules.dev
            self.homeModules.cockpit
          ];
          home.username = seat.user;
          home.homeDirectory = seat.home;
          home.stateVersion = config.system.stateVersion;
        };

        # git refuses another user's repo without this, and honours it only
        # from a global config file, never via -c or the environment.
        home-manager.users.${config.primaryUser}.programs.git.settings.safe.directory =
          "${seat.home}/ark/monix";

        # Address filter on every process this user runs, both directions and
        # all interfaces, including the tailnet, which Tailscale ACLs cannot
        # restrict per-user. Filtering is port-blind, so admitting 127.0.0.1
        # would expose every loopback service; llama-swap gets a dedicated
        # seat-plane address instead. The desktops are admitted for their
        # browser door, which is also port-blind: the seat can reach whatever
        # a desktop serves on its tailnet address, and nothing else there.
        systemd.slices."user-${toString seat.uid}".sliceConfig = {
          IPAddressAllow = [
            "127.0.0.53/32"
            "${topology.seatInferenceAddr}/32"
          ]
          ++ (topology.desktops |> attrValues |> map (a: "${a}/32"));
          IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
        };

        # Must exist before the first session keys its project state to it.
        systemd.tmpfiles.rules = singleton "d ${seat.home}/cockpit 0750 ${seat.user} ${seat.user} -";

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

        # Authentication, project trust and session state remain per-user;
        # host-owned MCP endpoints are immutable layers shared by every
        # agent frontend.
        environment.etc."codex/config.toml".source =
          toml.generate "codex-system-config.toml" cfg.codexConfig;
        environment.etc."claude-code/managed-settings.json".source =
          json.generate "claude-managed-settings.json" cfg.claudeSettings;

        seat.codexConfig.mcp_servers =
          browserServers topology
          |> mapAttrs (
            _: server:
            server
            // {
              default_tools_approval_mode = "writes";
              startup_timeout_sec = 20;
              tool_timeout_sec = 120;
            }
          );
        # hippo is the only memory; Claude's own would be a second writable
        # truth. Managed settings reach every launcher, Paseo included.
        seat.claudeSettings.autoMemoryEnabled = false;
        environment.etc."claude-code/managed-mcp.json".text = toJSON {
          mcpServers =
            browserServers topology
            |> mapAttrs (_: server: server // { type = if server ? url then "http" else "stdio"; });
        };
      };
    };
}
