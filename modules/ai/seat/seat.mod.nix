# The AI seat: one fenced, unprivileged account where Claude Code, Codex and
# OpenCode share the project state and hippo. Its home is composed here; the primary user's agent CLIs come from `dev` instead.
{
  inputs,
  lib,
  self,
  ...
}:
let
  # Parallel's keyless search, the one the assistants use, answers in well
  # under a second where the launchers' own search takes several and reads
  # worse on technical lookups.
  sharedServers = {
    web.url = "https://search.parallel.ai/mcp";
    cloudflare = {
      command = "/run/current-system/sw/bin/kestrel-cloudflare-mcp";
      args = [ ];
    };
  };
in
{
  flake.homeModules.cockpit =
    { lib, osConfig, ... }:
    let
      inherit (lib.ship) opencode topology;
      inherit (lib.attrsets) mapAttrs;
      inherit (lib.lists) singleton;
      inherit (lib.strings) toJSON;
    in
    {
      home.sessionVariables = opencode.environment;

      # Libri's omp turns read the same file; omp takes providers only from
      # its home. Forced, so a stray file there never fails activation.
      home.file.".omp/agent/models.yml".force = true;
      home.file.".omp/agent/models.yml".text = opencode.ompModels {
        keyFile = osConfig.secrets.opencode-key.path;
        deepseekKeyFile = osConfig.secrets.deepseek-key.path;
        abliterationKeyFile = osConfig.secrets.abliteration-key.path;
        local = {
          baseURL = "http://${topology.seatInferenceAddr}:${toString osConfig.inference.port}/v1";
          models = osConfig.inference.ompModels;
        };
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
            keyFile = osConfig.secrets.opencode-key.path;
            deepseekKeyFile = osConfig.secrets.deepseek-key.path;
            abliterationKeyFile = osConfig.secrets.abliteration-key.path;
            extraMcp =
              sharedServers
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
      inherit (lib.attrsets) mapAttrs;
      inherit (lib.lists) singleton;
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
        mcpServers = lib.options.mkOption {
          inherit (json) type;
          readOnly = true;
          description = "The seat's MCP servers, in Claude Code's shape.";
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
        # loopback address instead.
        systemd.slices."user-${toString seat.uid}".sliceConfig = {
          IPAddressAllow = [
            "127.0.0.53/32"
            "${topology.seatInferenceAddr}/32"
          ];
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
        # the host's policy is an immutable layer under every launcher.
        environment.etc."codex/config.toml".source =
          toml.generate "codex-system-config.toml" cfg.codexConfig;
        environment.etc."claude-code/managed-settings.json".source =
          json.generate "claude-managed-settings.json" cfg.claudeSettings;

        seat.codexConfig.mcp_servers =
          sharedServers
          |> mapAttrs (
            _: server:
            server
            // {
              default_tools_approval_mode = "writes";
              startup_timeout_sec = 20;
              tool_timeout_sec = 120;
            }
          );
        # Plain commits: Claude Code otherwise adds Co-Authored-By, PR text
        # and session links. Codex adds none unless codex_git_commit is on.
        seat.claudeSettings.attribution = false;
        # The engineer deploys routine changes; the auto-mode classifier would
        # otherwise refuse. Fenced deploys stay the captain's: `--approve`
        # asks for a wheel password.
        seat.claudeSettings.permissions.allow = [ "Bash(switcharoo)" ];
        seat.mcpServers =
          sharedServers
          |> mapAttrs (_: server: server // { type = if server ? url then "http" else "stdio"; });
      };
    };
}
