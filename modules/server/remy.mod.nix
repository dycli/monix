# The household chat bot (remy/bot.py): one Python service across two
# Matrix rooms, "Household" and "Scratchpad", the latter against its own
# scratch.db with the calendar read-only and no scheduled posts.
#
# Chat text only ever classifies into a fixed intent schema; there is no
# path from it to a shell, to SQL text or to the fleet.
#
# Three units share one static user, since DynamicUser cannot share
# /var/lib across units: remy-register bootstraps the account, remy itself
# is loopback-only, and remy-calendar-sync is the only unit with internet
# egress. The shared uid means the bot can read the CalDAV secret, which
# is accepted: that account is calendar-only and the bot's fence offers
# no way to use the credential elsewhere.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.remy;
  flake.nixosModules.remy =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) dirOf;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;

      cfg = config.remy;
      networkFences = import ../../lib/network-fences.nix;

      python = pkgs.python3.withPackages (ps: [
        ps.matrix-nio
        ps.requests
      ]);

      calPython = pkgs.python3.withPackages (ps: [ ps.caldav ]);

      # Tries a login first, then walks the registration-token UIA flow.
      # Idempotent.
      register = pkgs.writeShellApplication {
        name = "remy-register";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
        ];
        text = ''
          hs="http://127.0.0.1:${toString config.matrix.port}"
          localpart=''${MATRIX_USER#@}; localpart=''${localpart%%:*}
          mcurl() {
            curl -s --connect-timeout 5 --max-time 30 \
              -H "Content-Type: application/json" "$@"
          }

          login=$(mcurl -X POST "$hs/_matrix/client/v3/login" \
            -d "$(jq -n --arg u "$MATRIX_USER" --arg p "$MATRIX_PASSWORD" \
              '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')")
          tok=$(jq -r '.access_token // empty' <<< "$login")
          if [ -n "$tok" ]; then
            mcurl -X POST -H "Authorization: Bearer $tok" \
              "$hs/_matrix/client/v3/logout" -d '{}' > /dev/null || true
            echo "account $MATRIX_USER exists"
            exit 0
          fi

          session=$(mcurl -X POST "$hs/_matrix/client/v3/register" -d '{}' \
            | jq -er .session)
          out=$(mcurl -X POST "$hs/_matrix/client/v3/register" \
            -d "$(jq -n --arg u "$localpart" --arg p "$MATRIX_PASSWORD" \
                  --arg t "$TUWUNEL_REGISTRATION_TOKEN" --arg s "$session" \
              '{username:$u, password:$p, inhibit_login:true,
                auth:{type:"m.login.registration_token", token:$t, session:$s}}')")
          if jq -e '.user_id // empty' <<< "$out" > /dev/null; then
            echo "registered $MATRIX_USER"
          else
            echo "registration failed: $out" >&2
            exit 1
          fi
        '';
      };

      # Egress differs per unit and is set below.
      sandbox = (import ../../lib/hardened.nix).tenant // {
        User = "remy";
        Group = "remy";
        StateDirectory = "remy";
        StateDirectoryMode = "0700";
      };

      loopbackOnly = {
        IPAddressAllow = networkFences.loopback;
        IPAddressDeny = "any";
      };
    in
    {
      options.remy = {
        enable = mkEnableOption "the family household chat bot";

        credentialsEnvFile = mkOption {
          type = types.str;
          description = ''
            agenix env file with MATRIX_USER=@bot:server and
            MATRIX_PASSWORD=... — the bot's own Matrix account, its only
            credential. The account is auto-registered on first start.
          '';
        };

        registrationEnvFile = mkOption {
          type = types.str;
          description = ''
            agenix env file with TUWUNEL_REGISTRATION_TOKEN=... (the
            homeserver's, see matrix.mod.nix) — used only by the oneshot
            account-registration unit, never by the bot itself.
          '';
        };

        inviteUsers = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "@dylan:chat.example.com" ];
          description = ''
            Users invited when the bot creates its Household room on first
            start. The first entry also gets admin power in the room.
          '';
        };

        scratchpad.users = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "@captain:chat.example.com" ];
          description = ''
            Users invited to the bot's personal scratchpad room (notes,
            reminders, quick lists; own database, calendar read-only, no
            scheduled posts). The first entry gets admin power in the
            room. Empty list = no scratchpad room.
          '';
        };

        model = mkOption {
          type = types.str;
          default = "qwen3.6-35b-a3b";
          description = ''
            inference.models catalog id used for message parsing. The fast
            default model: classifying "we need X by friday" into JSON is
            squarely inside its weight class and keeps replies snappy.
          '';
        };

        morningTime = mkOption {
          type = types.str;
          default = "07:00";
          description = "Local HH:MM for the morning plan post.";
        };

        eveningTime = mkOption {
          type = types.str;
          default = "19:00";
          description = "Local HH:MM for the evening report post.";
        };

        logTime = mkOption {
          type = types.str;
          default = "23:50";
          description = ''
            Local HH:MM at which the bot composes and appends the day's entry
            to the family log (/var/lib/remy/log.md).
          '';
        };

        famlog = {
          path = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "/home/user/vault/notes/famlog.md";
            description = ''
              If set, a path unit mirrors the daily log here whenever it
              changes — e.g. into an Obsidian vault. The bot itself is fenced
              out of /home, so a separate root oneshot does the copy. null =
              no mirror (the log still lives at /var/lib/remy/log.md).
            '';
          };
          owner = mkOption {
            type = types.str;
            default = "root";
            description = "Owner of the mirrored file (the vault's user).";
          };
          group = mkOption {
            type = types.str;
            default = "root";
            description = "Group of the mirrored file.";
          };
        };

        calendar.credentialsFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            agenix JSON file listing CalDAV accounts to fold into the
            daily posts: [{"name":..., "url":..., "username":...,
            "password":...}, ...]. null = no calendar section.
          '';
        };

        calendar.daysAhead = mkOption {
          type = types.ints.positive;
          default = 30;
          description = "How far ahead the calendar sync fetches events.";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = config.matrix.enable && config.inference.enable;
            message = "remy needs the matrix homeserver and local inference aspects on this host";
          }
        ];

        users.users.remy = {
          isSystemUser = true;
          group = "remy";
        };
        users.groups.remy = { };

        systemd.services.remy-register = {
          description = "remy Matrix account bootstrap";
          wantedBy = [ "multi-user.target" ];
          wants = [ "tuwunel.service" ];
          after = [ "tuwunel.service" ];
          serviceConfig =
            sandbox
            // loopbackOnly
            // {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = getExe register;
              EnvironmentFile = [
                cfg.credentialsEnvFile
                cfg.registrationEnvFile
              ];
            };
        };

        systemd.services.remy = {
          description = "family household chat bot";
          wantedBy = [ "multi-user.target" ];
          # git_snapshot in bot.py commits a SQL dump on every mutation.
          path = [ pkgs.git ];
          wants = [
            "tuwunel.service"
            "remy-register.service"
          ];
          after = [
            "tuwunel.service"
            "remy-register.service"
            "llama-swap.service"
          ];
          environment = {
            BOT_HS_URL = "http://127.0.0.1:${toString config.matrix.port}";
            # The rooms are created once, so a renamed option would rename
            # nothing; the names stay the bot's own defaults.
            BOT_INVITE_USERS = lib.concatStringsSep "," cfg.inviteUsers;
            BOT_SCRATCH_USERS = lib.concatStringsSep "," cfg.scratchpad.users;
            BOT_SCRATCH_DB = "/var/lib/remy/scratch.db";
            LLM_URL = "http://127.0.0.1:${toString config.inference.port}/v1/chat/completions";
            LLM_MODEL = cfg.model;
            BOT_DB = "/var/lib/remy/home.db";
            BOT_CALENDAR_JSON = "/var/lib/remy/calendar.json";
            BOT_MORNING = cfg.morningTime;
            BOT_EVENING = cfg.eveningTime;
            BOT_LOG_TIME = cfg.logTime;
            BOT_TZ = config.time.timeZone;
          };
          serviceConfig =
            sandbox
            // loopbackOnly
            // {
              ExecStart = "${python}/bin/python ${./remy/bot.py}";
              EnvironmentFile = cfg.credentialsEnvFile;
              Restart = "always";
              RestartSec = 10;
            };
        };

        systemd.services.remy-calendar-sync = mkIf (cfg.calendar.credentialsFile != null) {
          description = "remy CalDAV calendar sync";
          environment = {
            REMY_CALDAV_CONFIG = cfg.calendar.credentialsFile;
            BOT_CALENDAR_JSON = "/var/lib/remy/calendar.json";
            BOT_DB = "/var/lib/remy/home.db";
            BOT_TZ = config.time.timeZone;
            REMY_CAL_DAYS = toString cfg.calendar.daysAhead;
          };
          serviceConfig = sandbox // {
            Type = "oneshot";
            ExecStart = "${calPython}/bin/python ${./remy/calsync.py}";
            # The only remy unit allowed out: CalDAV over HTTPS, plus
            # loopback.
            IPAddressAllow = networkFences.loopback;
            IPAddressDeny = networkFences.internetOnlyDeny;
          };
        };

        systemd.timers.remy-calendar-sync = mkIf (cfg.calendar.credentialsFile != null) {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = "30min";
          };
        };

        # The bot touches outbox.flag when chat queues an event, firing the
        # sync in seconds rather than waiting out the timer.
        systemd.paths.remy-calendar-sync = mkIf (cfg.calendar.credentialsFile != null) {
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathChanged = "/var/lib/remy/outbox.flag";
        };

        # The bot is fenced out of /home, so this root oneshot copies
        # log.md to the vault when it changes, owned by the vault's user.
        systemd.services.remy-famlog = mkIf (cfg.famlog.path != null) {
          description = "mirror remy's daily log into the vault";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = getExe (
              pkgs.writeShellApplication {
                name = "remy-famlog";
                runtimeInputs = [ pkgs.coreutils ];
                text = ''
                  src=/var/lib/remy/log.md
                  [ -f "$src" ] || exit 0
                  install -D -o ${cfg.famlog.owner} -g ${cfg.famlog.group} -m 0644 \
                    "$src" ${lib.escapeShellArg cfg.famlog.path}
                '';
              }
            );
            ProtectSystem = "strict";
            ReadWritePaths = [ (dirOf cfg.famlog.path) ];
            ReadOnlyPaths = [ "/var/lib/remy" ];
          };
        };

        systemd.paths.remy-famlog = mkIf (cfg.famlog.path != null) {
          wantedBy = [ "multi-user.target" ];
          # Watches the log itself: the append is the trigger, so a mirror
          # can never be silently skipped by a failed flag write.
          pathConfig.PathChanged = "/var/lib/remy/log.md";
        };
      };
    };
}
