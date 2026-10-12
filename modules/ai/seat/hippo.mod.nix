# hippo: the AI seat's episodic memory. One service, running as the seat,
# follows its Claude Code, Codex and OpenCode transcripts live and logs
# every chat word for word; sessions read it through the `hippo` CLI.
# Design: README, "hippo".
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
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      home.packages = lib.lists.singleton (package lib pkgs);
      # The service keeps the whole view in its store; as a user rule, Claude
      # Code loads it at session start and again after each compaction.
      home.file.".claude/rules/hippo-view.md".source =
        config.lib.file.mkOutOfStoreSymlink "${lib.ship.topology.seat.hippo}/view.md";
      # The assistants' notes to the seat, loaded the same way.
      home.file.".claude/rules/inbox.md".source =
        config.lib.file.mkOutOfStoreSymlink "${lib.ship.topology.household}/seat/inbox";
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

      # The compactor's model, through the seat's own claude CLI and
      # subscription. HIPPO_LEVELS can give lower tree levels a cheaper model
      # (e.g. "0=claude/claude-haiku-5-5/xhigh"); off while a week on Sonnet
      # alone measures the real cost.
      sonnet = {
        HIPPO_BACKEND = "claude";
        HIPPO_CLAUDE = "/etc/profiles/per-user/${seat.user}/bin/claude";
        HIPPO_MODEL = "sonnet";
        HIPPO_EFFORT = "medium";
      };
      compactor = sonnet;

      compactWindow = 200000;

      # Managed settings and system config, and so their hooks, reach every
      # user on the host; the hooks speak only to the seat.
      forSeat =
        name: body:
        pkgs.writeShellScript name ''
          [ "$(${pkgs.coreutils}/bin/id -u)" = ${toString seat.uid} ] || exit 0
          ${body}
        '';

      # The seat's context is about to be rewritten, so the view's next batch
      # of merges comes now: the fresh context opens on a view folded to half
      # its budget, with the stretch the summary covers merged rather than
      # raw. Milliseconds; a view that cannot fold yet is fine as it is.
      fold = "${lib.meta.getExe (package lib pkgs)} fold >&2 || true";

      # What a harness keeps of a conversation it compacts: hippo holds the
      # history and its view reloads afterwards, so the summary is only a
      # handoff.
      handoffText = ''
        This conversation is recorded word for word in hippo, the seat's
        memory; its view reloads into context by itself and `hippo zoom`
        opens any message. So the summary is a handoff, not a record, and
        it replaces the usual template: write exactly three short sections,
        Pending Tasks, Current Work (which files are dirty, what has been
        verified on them and how, what has not) and Next Step, plus one
        line for any decision or standing rule from the last few turns not
        yet acted on. Do not write Primary Request, Key Technical Concepts,
        Files and Code Sections, Errors and Fixes, Problem Solving or All
        User Messages, not even as empty headings: hippo holds them. What
        the bridge notes or the inbox already hold, name in a few words,
        never repeat. Hard limit 300 words. An earlier summary in this
        conversation is not a record either: carry nothing from it that is
        no longer live.'';

      # Claude Code takes the hook's output as its compaction instructions.
      handoff = forSeat "hippo-handoff" ''
        ${fold}
        ${pkgs.coreutils}/bin/cat <<'EOF'
        ${handoffText}
        EOF
      '';

      # Harnesses without rules files get the view and the inbox from a
      # session-start hook, at startup and again after each compaction.
      context = forSeat "hippo-context" ''
        ${pkgs.coreutils}/bin/cat ${seat.hippo}/view.md
        echo
        echo '# Inbox: notes from the household assistants'
        ${pkgs.coreutils}/bin/cat ${lib.ship.topology.household}/seat/inbox 2>/dev/null || true
      '';

      # The compactor's own claude calls get the seat's managed settings
      # without hooks or managed MCP servers: those would open the desktops'
      # browser doors on every call, and forbid --strict-mcp-config.
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
      };

      # Codex, as close as its hooks allow: the view and inbox open every
      # session and every compacted context, the view folds before each
      # compaction, the summary is the same handoff, and its own memories
      # stay off. Hooks in the system layer are managed, so need no trust.
      seat.codexConfig = {
        hooks.SessionStart = singleton {
          matcher = "startup|resume|clear|compact";
          hooks = singleton {
            type = "command";
            command = toString context;
            additionalContextLimit = 0;
          };
        };
        hooks.PreCompact = singleton {
          hooks = singleton {
            type = "command";
            command = toString (forSeat "hippo-fold" fold);
          };
        };
        compact_prompt = handoffText;
        model_auto_compact_token_limit = compactWindow;
        features.memories = false;
      };

      # OpenCode, through a plugin: its instruction files are re-read on
      # every prompt, which would change the system prompt with each
      # message and void the cache, so the plugin holds one snapshot of the
      # view and inbox per session, as the others do, and takes a fresh one
      # after the session compacts, folding first and summarising with the
      # handoff.
      home-manager.users.${seat.user}.home.file.".config/opencode/plugins/hippo.js".text = ''
        import { execFileSync } from "node:child_process";

        const context = ${toJSON (toString context)};
        const fold = ${toJSON (toString (forSeat "hippo-fold" fold))};
        const handoff = ${toJSON handoffText};
        const views = new Map();

        export const Hippo = async () => ({
          "experimental.chat.system.transform": async (input, output) => {
            if (!input.sessionID) return;
            if (!views.has(input.sessionID))
              views.set(input.sessionID, execFileSync(context, { encoding: "utf8" }));
            output.system.push(views.get(input.sessionID));
          },
          "experimental.session.compacting": async (input, output) => {
            execFileSync(fold, { stdio: "ignore" });
            views.delete(input.sessionID);
            output.prompt = handoff;
          },
        });
      '';

      # Seat sessions compact at 200k tokens; the view carries the history.
      # The variable, unlike the setting, leaves other users' sessions alone.
      systemd.services.paseo.environment.CLAUDE_CODE_AUTO_COMPACT_WINDOW = toString compactWindow;

      systemd.tmpfiles.rules = singleton "d ${seat.hippo} 0750 ${seat.user} ${seat.user} -";

      # A store is bootstrapped by `hippo import` (every past chat) before anything live enters it; the service starts once the
      # import has written its record.
      systemd.paths.hippo = {
        wantedBy = singleton "paths.target";
        pathConfig.PathExists = "${seat.hippo}/import.json";
      };

      systemd.services.hippo = {
        description = "hippo, the AI seat's episodic memory";
        wantedBy = singleton "multi-user.target";
        unitConfig.ConditionPathExists = "${seat.hippo}/import.json";
        # A switch restarts it after the reload: stopped first, hippo.path
        # would start it again on the old unit before the new one loads.
        stopIfChanged = false;
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
