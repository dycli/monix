# Cockpit: the user's primary interactive agent session. Claude Code over
# tmux/SSH and opencode web are interchangeable frontends to the same seat,
# carrying full user privileges (contrast the locked-down fleet workers of
# agent-vm.mod.nix). Agent tooling itself comes from packages.mod.nix /
# claude.mod.nix, gated on `isDesktop || cockpit.enable`.
{ inputs, ... }:
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
      userHome = "/home/${osConfig.primaryUser}";
      monixDir = "${userHome}/ark/monix";
      holdDir = "${userHome}/hold";
      cockpitDir = "${userHome}/cockpit";
      cockpitMemoryDir = "${userHome}/cockpit/memory";
      claudeMemoryDir = "${userHome}/.claude/projects/-home-max-cockpit/memory";
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
        "ship-status"
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
        ++ concatMap (path: [
          "Read(/${path}/**)"
          "Edit(/${path}/**)"
          "Write(/${path}/**)"
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
          text = builtins.toJSON {
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
        home.file.".claude/projects/-home-max-cockpit/memory" = {
          force = true;
          source = config.lib.file.mkOutOfStoreSymlink ("/home/${osConfig.primaryUser}/cockpit/memory");
        };

        # Declarative so the allowlist can't drift from what AGENTS.md
        # promises. The scoped-sudo fleet hop is allowed as one prefix rather
        # than per-subcommand, since the immutable fleet tool is the boundary.
        home.file."cockpit/.claude/settings.json" = {
          force = true;
          text = builtins.toJSON {
            permissions = {
              allow = claudeAllow;
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
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;
    in
    {
      options.cockpit.enable = mkEnableOption "the persistent cockpit session role on this host";

      options.cockpit.webEnable = mkEnableOption "the opencode web cockpit seat";

      options.cockpit.webEnvFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          EnvironmentFile holding OPENCODE_SERVER_PASSWORD=<basic-auth pw>
          for the opencode web UI; null = no web UI. This is the app-local
          password layer. If the UI is exposed beyond the tailnet, put
          Cloudflare Access in front too: opencode web controls a shell-capable
          cockpit seat.
        '';
      };

      options.cockpit.webTunnelTokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Cloudflare Tunnel connector token for exposing the opencode web
          cockpit at ai.su.is; null = no public tunnel. The public hostname
          and origin service are managed in Cloudflare Zero Trust.
        '';
      };

      config = mkIf config.cockpit.enable {
        assertions = [
          {
            assertion = config.cockpit.webTunnelTokenFile == null || config.cockpit.webEnable;
            message = "cockpit.webTunnelTokenFile requires cockpit.webEnable";
          }
        ];

        # tmux is the session's persistence layer; the binary is already
        # system-wide (packages-shell-utils), this adds the /etc config.
        programs.tmux.enable = true;
        programs.tmux.historyLimit = 50000;

        # python3/jq keep everyday data munging off the `nix shell
        # nixpkgs#python3` path, which prompted on every use.
        environment.systemPackages = [
          inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
          pkgs.python3
          pkgs.jq
        ];

        # Runs AS the primary user (needs their auth.json/home/tooling, so
        # not filesystem-sandboxed like a tenant service). Binds to loopback
        # behind nginx; Cloudflare Tunnel is the public ingress when enabled.
        services.nginx = mkIf config.cockpit.webEnable {
          enable = true;
          recommendedProxySettings = true;
          virtualHosts."opencode-web-cockpit" = {
            listen = singleton {
              addr = "127.0.0.1";
              port = 4096;
            };
            locations."/" = {
              proxyPass = "http://127.0.0.1:4097";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_buffering off;
              '';
            };
          };
        };

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
            "/etc/profiles/per-user/${config.primaryUser}"
          ];
          serviceConfig = {
            User = config.primaryUser;
            Group = "users";
            Slice = "cockpit.slice";
            EnvironmentFile = mkIf (config.cockpit.webEnvFile != null) config.cockpit.webEnvFile;
            WorkingDirectory = "/home/${config.primaryUser}/cockpit";
            ExecStart = "${getExe pkgs.opencode} web --hostname 127.0.0.1 --port 4097 --cors https://ai.su.is --print-logs";
            Restart = "always";
            RestartSec = 3;
          };
        };

        # A remote session must not consume every byte or PID on the host.
        systemd.slices.cockpit.sliceConfig = mkIf config.cockpit.webEnable {
          MemoryHigh = "48G";
          MemoryMax = "64G";
          TasksMax = 8192;
        };

        systemd.services.opencode-web-tunnel = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Cloudflare Tunnel for opencode web";
          wantedBy = [ "multi-user.target" ];
          partOf = [
            "nginx.service"
            "opencode-web.service"
          ];
          wants = [
            "network-online.target"
            "nginx.service"
            "opencode-web.service"
          ];
          after = [
            "network-online.target"
            "nginx.service"
            "opencode-web.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = [ "token:${config.cockpit.webTunnelTokenFile}" ];
            ExecStart = "${getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
          };
          environment = {
            TUNNEL_TRANSPORT_PROTOCOL = "http2";
          };
        };

        # Cloudflare Access is configured outside Nix; probe without a cookie
        # so dashboard drift can't silently turn this endpoint public again.
        systemd.services.opencode-web-access-check = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Verify Cloudflare Access protects the opencode cockpit";
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "opencode-web-tunnel.service"
          ];
          path = [ pkgs.curl ];
          serviceConfig = {
            Type = "oneshot";
            DynamicUser = true;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
          };
          script = ''
            # Three attempts per URL: a single timeout or Cloudflare hiccup
            # is not dashboard drift, and since unit failures page the alert
            # room (alerts.mod.nix) a one-shot probe was too trigger-happy.
            # An endpoint that actually answers without demanding Access
            # still fails every attempt and alerts within the same run.
            check() {
              for attempt in 1 2 3; do
                [ "$attempt" -gt 1 ] && sleep 10
                result="$(curl --silent --show-error --max-time 20 --output /dev/null \
                  --write-out '%{http_code} %{redirect_url}' "$1")" || result="curl error"
                case "$result" in
                  302\ https://*.cloudflareaccess.com/*) return 0 ;;
                esac
              done
              echo "Cloudflare Access check failed for $1: $result" >&2
              exit 1
            }
            check https://ai.su.is/
            check https://ai.su.is/session
          '';
        };

        systemd.timers.opencode-web-access-check = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Periodically verify Cloudflare Access";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = "5m";
            Unit = "opencode-web-access-check.service";
          };
        };
      };
    };
}
