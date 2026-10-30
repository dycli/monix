# hippo: the AI seat's episodic memory. One service, running as the seat,
# follows its Claude Code, Codex, Muse Code and OpenCode transcripts live and logs
# every chat word for word; sessions read it through the `hippo` CLI.
# Design: README, "hippo".
{ self, ... }:
let
  # Libri's repository holds hippo; the seat runs the build its link points
  # at, as Libri does (deploy_libri.sh keeps the link).
  package =
    lib: pkgs:
    lib.ship.libriHippo pkgs lib.ship.topology.seat.libriBuild {
      HIPPO_DIR = lib.ship.topology.seat.hippo;
      HIPPO_ARCHIVE = lib.ship.topology.seat.transcripts;
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
      inherit (lib.strings) toJSON;
      inherit (topology) seat;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib) types;

      door = config.hippo.door;
      doorPort = 8940;

      # The compactor reaches its model through Libri, on the socket in the
      # store: the person picks it in Libri's Settings, and hippo holds no
      # login and no key.
      compactor.HIPPO_BACKEND = "libri";

      compactWindow = 200000;

      # Managed settings and system config, and so their hooks, reach every
      # user on the host; the hooks speak only to the seat.
      forSeat =
        name: body:
        pkgs.writeShellScript name ''
          [ "$(${pkgs.coreutils}/bin/id -u)" = ${toString seat.uid} ] || exit 0
          # Under Libri, which brings the view and folds it itself.
          [ -z "''${LIBRI_RUNNING:-}" ] || exit 0
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
        it replaces the usual template. The view holds every chat at once,
        so open with one line naming this chat's work: the project, its
        repository or directory, and the captain's latest request in their
        words. Then write exactly three short sections,
        Pending Tasks, Current Work (which files are dirty, what has been
        verified on them and how, what has not) and Next Step, plus one
        line for any decision or standing rule from the last few turns not
        yet acted on. Do not write Primary Request, Key Technical Concepts,
        Files and Code Sections, Errors and Fixes, Problem Solving or All
        User Messages, not even as empty headings: hippo holds them. What
        the bridge notes already hold, name in a few words,
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

      # Harnesses without rules files get the view from a
      # session-start hook, at startup and again after each compaction.
      context =
        harness:
        forSeat "hippo-context-${harness}" ''
          ${pkgs.coreutils}/bin/cat ${seat.hippo}/view.md
          ${own harness}
        '';

      # The view holds every chat in one timeline, so a compacted or resumed
      # chat also gets its own latest words, verbatim, after it: the session
      # id comes on the hook's stdin. Last, so the view's cache holds.
      own =
        harness:
        forSeat "hippo-own-${harness}" ''
          id=$(${lib.meta.getExe pkgs.jq} -r '.session_id // .sessionId // empty' 2>/dev/null)
          [ -n "$id" ] || exit 0
          ${pkgs.coreutils}/bin/timeout 5 ${lib.meta.getExe (package lib pkgs)} chat ${harness} "$id" | ${pkgs.gnused}/bin/sed '1s/^/\n/' || true
        '';
    in
    {
      options.hippo.door = {
        passphraseFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Passphrase for the seat's door (hippo.<domain> -> http://127.0.0.1:${toString doorPort}), 12 characters or more; null = no door.";
        };
        tunnelTokenFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Cloudflare Tunnel connector token carrying every hippo door out, the yeomen's too; null = no tunnel.";
        };
      };

      config = {
        seat.claudeSettings.hooks = {
          PreCompact = singleton {
            hooks = singleton {
              type = "command";
              command = toString handoff;
            };
          };
          # The view itself is a rules file; only the chat's own words come
          # from a hook.
          SessionStart = singleton {
            matcher = "resume|compact";
            hooks = singleton {
              type = "command";
              command = toString (own "claude");
            };
          };
        };

        # Codex, as close as its hooks allow: the view opens every
        # session and every compacted context, the view folds before each
        # compaction, the summary is the same handoff, and its own memories
        # stay off. Hooks in the system layer are managed, so need no trust.
        seat.codexConfig = {
          hooks.SessionStart = singleton {
            matcher = "startup|resume|clear|compact";
            hooks = singleton {
              type = "command";
              command = toString (context "codex");
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

        # Muse, through its managed hooks file, which runs without a trust
        # step. Muse kills a hook printing over 16 KB and cuts a rules file at
        # about 32 KB, so the view comes as consecutive slices of
        # under 15,000 bytes, one hook each, which Muse joins in order: twelve
        # cover the 128 KB view with room to spare. Its
        # compaction prompt is not configurable; the fold still runs first.
        seat.museHooks =
          let
            slice =
              n:
              forSeat "hippo-context-${toString n}" ''
                ${context "muse"} | LC_ALL=C ${pkgs.gawk}/bin/awk -v n=${toString n} '
                  { l = length($0) + 1; if (b > 0 && b + l > 15000) { p++; b = 0 }; b += l }
                  p == n { print }'
              '';
          in
          {
            SessionStart = singleton {
              matcher = "startup|resume|compact";
              hooks = lib.lists.genList (n: {
                type = "command";
                command = toString (slice n);
              }) 12;
            };
            PreCompact = singleton {
              hooks = singleton {
                type = "command";
                command = toString (forSeat "hippo-fold" fold);
              };
            };
          };

        # OpenCode, through a plugin: its instruction files are re-read on
        # every prompt, which would change the system prompt with each
        # message and void the cache, so the plugin holds one snapshot of the
        # view per session, as the others do, and takes a fresh one
        # after the session compacts, folding first and summarising with the
        # handoff.
        home-manager.users.${seat.user}.home.file.".config/opencode/plugins/hippo.js".text = ''
          import { execFileSync } from "node:child_process";

          const context = ${toJSON (toString (context "opencode"))};
          const fold = ${toJSON (toString (forSeat "hippo-fold" fold))};
          const handoff = ${toJSON handoffText};
          const views = new Map();

          export const Hippo = async () => ({
            "experimental.chat.system.transform": async (input, output) => {
              if (!input.sessionID) return;
              if (!views.has(input.sessionID))
                views.set(input.sessionID, execFileSync(context, {
                    encoding: "utf8",
                    input: JSON.stringify({ session_id: input.sessionID }),
                  }));
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
            HIPPO_AGENT = "Bridge";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            User = seat.user;
            Group = seat.user;
            ExecStart = "${lib.meta.getExe (package lib pkgs)} serve code";
            WorkingDirectory = seat.hippo;
            Restart = "always";
            RestartSec = 5;
            # Reads the seat's transcripts; writes its own store.
            ProtectHome = "read-only";
            # SQLite needs OpenCode's WAL index writable even to read.
            ReadWritePaths = [
              seat.hippo
              "-${seat.home}/.local/share/opencode"
            ];
            RestrictAddressFamilies = [ "AF_UNIX" ];
            # The primary user reads the store through the seat's group.
            UMask = "0027";
          };
        };

        # The doors: each memory, read-only, as a remote MCP server for
        # apps outside the ship (Claude, Grok), on its own hostname and
        # passphrase (lib/hippo-door.nix); this one is the seat's. One
        # tunnel carries every door; hostnames map to ports dashboard-side.
        systemd.services.hippo-door = mkIf (door.passphraseFile != null) (
          lib.ship.hippoDoor {
            hippo = package lib pkgs;
            service = "hippo.service";
            dir = seat.hippo;
            inherit (seat) user;
            agent = "Bridge";
            person = "Dylan";
            port = doorPort;
            host = "hippo.${config.shipProxy.domain}";
            inherit (door) passphraseFile;
          }
        );

        systemd.services.hippo-tunnel = mkIf (door.tunnelTokenFile != null) {
          description = "Cloudflare Tunnel for the hippo doors";
          wantedBy = singleton "multi-user.target";
          wants = singleton "network-online.target";
          after = singleton "network-online.target";
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = singleton "token:${door.tunnelTokenFile}";
            ExecStart = "${lib.meta.getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
            # Cloudflare's edge and loopback only; 127.0.0.0/8 is denied
            # because the allow is a /24.
            IPAddressAllow = fences.loopback;
            IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          };
          environment.TUNNEL_TRANSPORT_PROTOCOL = "http2";
        };
      };
    };
}
