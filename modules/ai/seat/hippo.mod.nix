# hippo: the AI seat's episodic memory. One service, running as the seat,
# follows its Claude Code, Codex and OpenCode transcripts live and logs
# every chat word for word; sessions read it through the `hippo` CLI.
# Design: ~/cockpit/hippo/SPEC.md.
{ self, ... }:
let
  package =
    lib: pkgs:
    lib.ship.rustTool pkgs {
      src = ./hippo;
      env = {
        HIPPO_DIR = lib.ship.topology.seat.hippo;
        HIPPO_ARCHIVE = lib.ship.topology.seat.transcripts;
      };
    };
in
{
  # Straight into the seat's bundle: a homeModules.hippo would be mirrored
  # onto the host's primary user (options/flake-outputs.mod.nix).
  flake.homeModules.cockpit =
    { lib, pkgs, ... }:
    {
      home.packages = lib.lists.singleton (package lib pkgs);
      # Seat sessions compact at 200k tokens; the view carries the history.
      home.sessionVariables.CLAUDE_CODE_AUTO_COMPACT_WINDOW = "200000";
    };

  flake.nixosModules.seat = self.nixosModules.hippo;
  flake.nixosModules.hippo =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.ship) fences topology;
      inherit (lib.attrsets) removeAttrs;
      inherit (lib.strings) toJSON;
      inherit (topology) seat;

      # The compactor's model. Sonnet at medium effort runs through the seat's
      # own claude CLI and subscription; Qwen runs on the host's llama-swap at
      # no subscription cost, one call at a time.
      sonnet = {
        HIPPO_BACKEND = "claude";
        HIPPO_CLAUDE = "/etc/profiles/per-user/${seat.user}/bin/claude";
        HIPPO_MODEL = "sonnet";
        HIPPO_EFFORT = "medium";
      };
      qwen = {
        HIPPO_BACKEND = "http";
        HIPPO_URL = "http://${topology.seatInferenceAddr}:${toString config.inference.port}/v1";
        HIPPO_MODEL = "qwen3.8-27b-q4-k-m";
        # Qwen's reasoning level and its recommended thinking-mode sampling.
        HIPPO_HTTP_EXTRA = toJSON {
          chat_template_kwargs.reasoning_effort = "medium";
          # Caps a reply that loops in its thinking; medium needs ~2k.
          max_tokens = 8192;
          temperature = 1.0;
          top_p = 0.95;
          top_k = 20;
        };
      };
      compactor = sonnet;

      compactWindow = 200000;

      # Managed settings and their hooks reach every user on the host; the
      # hooks speak only to the seat.
      forSeat =
        name: text:
        pkgs.writeShellScript name ''
          [ "$(${pkgs.coreutils}/bin/id -u)" = ${toString seat.uid} ] || exit 0
          ${pkgs.coreutils}/bin/cat <<'EOF'
          ${text}
          EOF
        '';

      # What Claude Code keeps of a conversation it compacts: hippo holds the
      # history, so the summary is only a handoff that sends the session back
      # to the view.
      handoff = forSeat "hippo-handoff" ''
        This conversation is recorded word for word in hippo, the seat's
        memory. Do not summarize its history. Write only the task in
        progress and its exact state, the next step, and anything decided
        in the last few turns that is not yet acted on. End with this line:
        Context was compacted: run `hippo view` now and read every page.'';

      # Printed into a seat session that was compacted or cleared.
      reload = forSeat "hippo-reload" "Your context was reset. Run `hippo view` now and read every page before you go on.";

      # The compactor's own claude calls get the seat's managed settings
      # without hooks or managed MCP servers: those would start a browser and
      # Tailscale SSH sessions on every call, and forbid --strict-mcp-config.
      claudeEtc = pkgs.writeTextDir "managed-settings.json" (
        toJSON (removeAttrs config.seat.claudeSettings (singleton "hooks"))
      );
    in
    {
      seat.claudeSettings.hooks = {
        PreCompact = singleton {
          hooks = singleton {
            type = "command";
            command = toString handoff;
          };
        };
        SessionStart = singleton {
          matcher = "compact|clear";
          hooks = singleton {
            type = "command";
            command = toString reload;
          };
        };
      };

      # Seat sessions compact at 200k tokens; the view carries the history.
      # The variable, unlike the setting, leaves other users' sessions alone.
      systemd.services.paseo.environment.CLAUDE_CODE_AUTO_COMPACT_WINDOW = toString compactWindow;

      systemd.tmpfiles.rules = singleton "d ${seat.hippo} 0750 ${seat.user} ${seat.user} -";

      # A store is bootstrapped by `hippo import` (OptMem's notes and every
      # past chat) before anything live enters it; the service starts once the
      # import has written its record.
      systemd.paths.hippo = {
        wantedBy = singleton "paths.target";
        pathConfig.PathExists = "${seat.hippo}/import.json";
      };

      systemd.services.hippo = {
        description = "hippo, the AI seat's episodic memory";
        wantedBy = singleton "multi-user.target";
        unitConfig.ConditionPathExists = "${seat.hippo}/import.json";
        after = singleton "network-online.target";
        wants = singleton "network-online.target";
        unitConfig.RequiresMountsFor = [
          "/srv/storage"
          seat.home
        ];
        environment = compactor // {
          HOME = seat.home;
        };
        serviceConfig = lib.ship.hardened.tenant // {
          User = seat.user;
          Group = seat.user;
          ExecStart = "${lib.meta.getExe (package lib pkgs)} serve";
          WorkingDirectory = seat.hippo;
          Restart = "always";
          RestartSec = 5;
          # Reads the seat's transcripts; writes its own store, and the claude
          # CLI's state and refreshed credentials.
          ProtectHome = "read-only";
          # SQLite needs OpenCode's WAL index writable even to read.
          ReadWritePaths = [
            seat.hippo
            "-${seat.home}/.local/share/opencode"
            "${seat.home}/.claude"
            "${seat.home}/.claude.json"
          ];
          BindReadOnlyPaths = singleton "${claudeEtc}:/etc/claude-code";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          # The seat's own fence: the internet, the resolver and local inference.
          IPAddressAllow = [
            "127.0.0.53/32"
            "${topology.seatInferenceAddr}/32"
          ];
          IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          # The primary user reads the store through the seat's group.
          UMask = "0027";
        };
      };
    };
}
