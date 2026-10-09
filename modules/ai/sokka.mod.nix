# Sokka, the household assistant (sokka/): one endless Matrix chat with no
# sessions, run once per person (`sokka.instances`), each with its own
# account, memory, book and chat. Each message from its person becomes one
# fresh model call over the prompt, the whole memory and the message;
# message and answer both go into that instance's own hippo store, so the
# next call remembers them.
#
# Each instance is three units under its own static user: the bot, the
# hippo service that is the store's only writer, and the account
# bootstrap. Model calls run the claude CLI on the fleet's subscription
# token, without built-in tools or settings; their only tools come over
# MCP: web search and fetch (sokka-web.py, in front of Parallel's keyless
# server), the instance's own
# reminders, lists and memory tools (`sokka tools`: zoom, search and date
# in its hippo, as the seat's hippo CLI has), which reach only its book
# and its hippo, the shared calendar (sokka-calendar.py over CalDAV), mail
# where the instance has some (sokka-mail.py over IMAP, read-only), each
# the only process that sees its login, and YouTube search and captions
# (sokka-youtube.py), which reaches YouTube only. Mail and pages let
# anyone put text in front of the model, so fetch opens only links a
# search returned or the person wrote: nothing it read can ride out in a
# link it made up. The bot sends due reminders itself, runs
# due routines as requests and sends the answers, reads photos and files
# sent to it without keeping them, and on the one instance that takes
# them, reads the host's alerts from their spool and sends its own account
# of them (alerts.mod.nix).
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.sokka;
  flake.nixosModules.sokka =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists)
        singleton
        optional
        length
        head
        ;
      inherit (lib.meta) getExe;
      inherit (lib.strings) readFile concatStringsSep toSentenceCase;
      inherit (lib.options) mkOption;
      inherit (lib.attrsets)
        optionalAttrs
        attrNames
        filterAttrs
        mapAttrs
        mapAttrsToList
        ;
      inherit (lib.modules) mkIf mkMerge;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.sokka;

      sokka = lib.ship.rustTool pkgs { src = ./sokka; };
      hippo = lib.ship.rustTool pkgs { src = ./seat/hippo; };

      calendar = pkgs.writers.writePython3Bin "sokka-calendar" {
        libraries = ps: [
          ps.caldav
          ps.mcp
        ];
        flakeIgnore = singleton "E501";
      } (readFile ./sokka-calendar.py);

      mail = pkgs.writers.writePython3Bin "sokka-mail" {
        libraries = ps: [
          ps.imapclient
          ps.mcp
        ];
        flakeIgnore = singleton "E501";
      } (readFile ./sokka-mail.py);

      web = pkgs.writers.writePython3Bin "sokka-web" {
        libraries = singleton pkgs.python3Packages.mcp;
        flakeIgnore = singleton "E501";
      } (readFile ./sokka-web.py);

      youtube = pkgs.writers.writePython3Bin "sokka-youtube" {
        libraries = ps: [
          ps.yt-dlp
          ps.mcp
        ];
        flakeIgnore = singleton "E501";
      } (readFile ./sokka-youtube.py);

      # The token rides a systemd credential into the environment, never
      # the command line.
      claude = pkgs.writeShellApplication {
        name = "sokka-claude";
        text = ''
          CLAUDE_CODE_OAUTH_TOKEN=$(< "$CREDENTIALS_DIRECTORY/claude-token")
          export CLAUDE_CODE_OAUTH_TOKEN
          exec ${getExe pkgs.claude-code} "$@"
        '';
      };

      # Hides the host's managed settings and MCP servers (the seat's), which
      # would forbid --strict-mcp-config.
      claudeEtc = pkgs.writeTextDir "managed-settings.json" "{}";

      # Idempotent: logs in first, else walks the registration-token flow.
      register = pkgs.writeShellApplication {
        name = "sokka-register";
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

          # /proc/<pid>/cmdline is world-readable: jq reads the secrets from
          # the environment, request bodies ride stdin, and the bearer
          # header goes to curl as a -K - config.
          login=$(jq -n '{type:"m.login.password",
              identifier:{type:"m.id.user",user:env.MATRIX_USER},
              password:env.MATRIX_PASSWORD}' \
            | mcurl -X POST "$hs/_matrix/client/v3/login" -d @-)
          tok=$(jq -r '.access_token // empty' <<< "$login")
          if [ -n "$tok" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$tok" \
              | mcurl -K - -X POST "$hs/_matrix/client/v3/logout" \
                  -d '{}' > /dev/null || true
            echo "account $MATRIX_USER exists"
            exit 0
          fi

          session=$(mcurl -X POST "$hs/_matrix/client/v3/register" -d '{}' \
            | jq -er .session)
          out=$(localpart="$localpart" session="$session" jq -n \
              '{username:env.localpart, password:env.MATRIX_PASSWORD,
                inhibit_login:true,
                auth:{type:"m.login.registration_token",
                      token:env.TUWUNEL_REGISTRATION_TOKEN, session:env.session}}' \
            | mcurl -X POST "$hs/_matrix/client/v3/register" -d @-)
          if jq -e '.user_id // empty' <<< "$out" > /dev/null; then
            echo "registered $MATRIX_USER"
          else
            echo "registration failed: $out" >&2
            exit 1
          fi
        '';
      };

      # The homeserver and resolver on loopback, and the internet for the
      # model; not the tailnet, the LAN or the seat's loopback address.
      fence = {
        IPAddressAllow = fences.loopback;
        IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
      };

      # The three units of one instance.
      services =
        n: i:
        let
          state = "/var/lib/${n}";
          creds = "/run/credentials/${n}.service";
          env = {
            HOME = state;
            HIPPO_DIR = "${state}/hippo";
          };

          mcp = (pkgs.formats.json { }).generate "${n}-mcp.json" {
            mcpServers = {
              web = {
                type = "stdio";
                command = getExe web;
                env.HIPPO_DIR = env.HIPPO_DIR;
              };
              sokka = {
                type = "stdio";
                command = getExe sokka;
                args = [
                  "tools"
                  state
                ];
                env.HIPPO_DIR = env.HIPPO_DIR;
              };
              calendar = {
                type = "stdio";
                command = getExe calendar;
                args = singleton "${creds}/caldav";
                env.SOKKA_TZ = config.time.timeZone;
              };
              youtube = {
                type = "stdio";
                command = getExe youtube;
              };
            }
            // optionalAttrs (i.mailCredentialsFile != null) {
              mail = {
                type = "stdio";
                command = getExe mail;
                args = singleton "${creds}/mail";
                env.SOKKA_IMAP = cfg.mailServer;
              };
            };
          };

          sandbox = lib.ship.hardened.tenant // {
            User = n;
            Group = n;
            StateDirectory = n;
            StateDirectoryMode = "0700";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
          };

          # Each claude call writes its state under HOME.
          claudeUnit = {
            LoadCredential = "claude-token:${cfg.claudeTokenFile}";
            BindReadOnlyPaths = singleton "${claudeEtc}:/etc/claude-code";
          };
        in
        {
          "${n}-register" = {
            description = "${i.name} Matrix account bootstrap";
            wantedBy = singleton "multi-user.target";
            wants = singleton "tuwunel.service";
            after = singleton "tuwunel.service";
            serviceConfig =
              sandbox
              // fence
              // {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = getExe register;
                EnvironmentFile = [
                  i.credentialsEnvFile
                  cfg.registrationEnvFile
                ];
              };
          };

          "${n}-hippo" = {
            description = "${i.name}'s memory";
            wantedBy = singleton "multi-user.target";
            environment = env // {
              HIPPO_AGENT = i.name;
              HIPPO_VIEW = toString cfg.viewBytes;
              HIPPO_BACKEND = "claude";
              HIPPO_CLAUDE = getExe claude;
              HIPPO_MODEL = "sonnet";
              HIPPO_EFFORT = "medium";
            };
            serviceConfig =
              sandbox
              // fence
              // claudeUnit
              // {
                StateDirectory = [
                  n
                  "${n}/hippo"
                ];
                ExecStart = "${getExe hippo} serve --no-follow";
                Restart = "always";
                RestartSec = 5;
              };
          };

          ${n} = {
            description = "${i.name}, ${i.person}'s household assistant";
            wantedBy = singleton "multi-user.target";
            wants = [
              "tuwunel.service"
              "${n}-register.service"
              "${n}-hippo.service"
            ];
            after = [
              "tuwunel.service"
              "${n}-register.service"
              "${n}-hippo.service"
            ];
            environment =
              env
              // {
                SOKKA_NAME = i.name;
                SOKKA_PERSON = i.person;
                SOKKA_HOMESERVER = "http://127.0.0.1:${toString config.matrix.port}";
                SOKKA_USERS = concatStringsSep "," i.users;
                SOKKA_BACKEND = "claude";
                SOKKA_CLAUDE = getExe claude;
                SOKKA_MODEL = cfg.model;
                SOKKA_MCP = toString mcp;
              }
              // optionalAttrs (i.style != null) { SOKKA_STYLE = i.style; }
              // optionalAttrs i.alerts { SOKKA_ALERTS = config.alerts.spool; };
            serviceConfig =
              sandbox
              // fence
              // claudeUnit
              // {
                ExecStart = getExe sokka;
                EnvironmentFile = i.credentialsEnvFile;
                LoadCredential = [
                  "claude-token:${cfg.claudeTokenFile}"
                  "caldav:${cfg.calendarCredentialsFile}"
                ]
                ++ optional (i.mailCredentialsFile != null) "mail:${i.mailCredentialsFile}";
                Restart = "always";
                RestartSec = 10;
              }
              // optionalAttrs i.alerts { ReadWritePaths = singleton config.alerts.spool; };
          };
        };

      alerted = attrNames (filterAttrs (_: i: i.alerts) cfg.instances);
    in
    {
      options.sokka = {
        instances = mkOption {
          description = ''
            One assistant per person, keyed by its unit, user and state
            directory name.
          '';
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  name = mkOption {
                    type = types.str;
                    default = toSentenceCase name;
                    description = "What the assistant is called.";
                  };

                  person = mkOption {
                    type = types.str;
                    example = "Alice";
                    description = "The person it serves, by first name.";
                  };

                  users = mkOption {
                    type = types.listOf types.str;
                    example = singleton "@alice:chat.example.com";
                    description = ''
                      Who it talks with: it joins rooms they invite it to and
                      answers only them.
                    '';
                  };

                  credentialsEnvFile = mkOption {
                    type = types.str;
                    description = ''
                      agenix env file with MATRIX_USER=@name:server and
                      MATRIX_PASSWORD=..., the assistant's own Matrix
                      account, registered on first start.
                    '';
                  };

                  mailCredentialsFile = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = ''
                      agenix JSON file with the person's IMAP accounts:
                      [{"name", "username", "password"}, ...]; null for no
                      mail.
                    '';
                  };

                  style = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "Be a little warm.";
                    description = "A line on tone, added to the prompt.";
                  };

                  alerts = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Whether it posts the host's alerts.";
                  };
                };
              }
            )
          );
        };

        registrationEnvFile = mkOption {
          type = types.str;
          description = ''
            agenix env file with TUWUNEL_REGISTRATION_TOKEN=..., used only by
            the account-registration oneshots.
          '';
        };

        claudeTokenFile = mkOption {
          type = types.str;
          description = "File holding a Claude Code OAuth token.";
        };

        calendarCredentialsFile = mkOption {
          type = types.str;
          description = ''
            agenix JSON file with the shared CalDAV accounts:
            [{"name", "url", "username", "password"}, ...].
          '';
        };

        mailServer = mkOption {
          type = types.str;
          example = "imap.example.com";
          description = "IMAP server of the mail accounts, over TLS on 993.";
        };

        model = mkOption {
          type = types.str;
          default = "opus";
          description = "Claude model that answers.";
        };

        viewBytes = mkOption {
          type = types.ints.positive;
          default = 128000;
          description = "Budget of each memory view, sent with every call.";
        };
      };

      config = {
        assertions = singleton {
          assertion = length alerted <= 1;
          message = "sokka: only one instance can take the alerts.";
        };

        # Sensors and the receiver write alerts in as root or the reader;
        # nobody else may, since what it posts its memory keeps.
        alerts.reader = mkIf (alerted != [ ]) (head alerted);

        users.users = mapAttrs (n: _: {
          isSystemUser = true;
          group = n;
          home = "/var/lib/${n}";
        }) cfg.instances;
        users.groups = mapAttrs (_: _: { }) cfg.instances;

        systemd.services = mkMerge (mapAttrsToList services cfg.instances);
      };
    };
}
