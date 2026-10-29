# The yeoman (yeoman/), the household's assistant program: one endless
# Matrix chat with no sessions, run once per person (`yeoman.instances`,
# Sokka for one, Suki for another), each with its own account, memory,
# book and chat. Each message from its person becomes one
# fresh model call over the prompt, the whole memory and the message;
# message and answer both go into that instance's own hippo store, so the
# next call remembers them.
#
# Each instance is three units under its own static user: the bot, the
# hippo service that is the store's only writer, and the account
# bootstrap. Model calls run the claude CLI on the ship's Claude subscription
# token (or an instance's own API key, `claudeKeyFile`), without built-in tools or settings; their only tools come over
# MCP: the instance's own server (`yeoman tools`: web search and fetch in
# front of Parallel's keyless server, reminders, lists, memory tools that
# zoom, search and date in its hippo as the seat's hippo CLI does, the
# shared calendar over CalDAV, mail where the instance has some, read-only
# over IMAP, YouTube search and captions through yt-dlp, which reaches
# YouTube only, and film and show requests, going over Seerr on loopback
# only with `requestsKeyFile` set), which reaches only its book, its hippo
# and those services, and pictures (yeoman-image.py), drawn either by the
# image service, the only assistant-side holder of a Codex login (the
# seat keeps its own, for paseo), or by Grok
# Imagine through the X service, and X, read by Grok's x_search through
# the X service (`yeoman x`, yeoman/src/x.rs) that alone holds the
# subscription's xAI sign-in; `yeoman tools`
# also reads the subscription
# limits from the usage service (usage.mod.nix). Mail and pages let
# anyone put text in front of the model, so fetch opens only links a
# search returned or the person wrote: nothing it read can ride out in a
# link it made up. The bot sends due reminders itself, runs
# due routines as requests and sends the answers, reads photos and files
# sent to it without keeping them, and on the one instance that takes
# them, reads the host's alerts from their spool and sends its own account
# of them (alerts.mod.nix). An instance with `computer = true` also drives
# a browser of its own on the host (assistant-browser.mod.nix) over
# Playwright MCP, reads its desk for screenshots, runs code in a microVM
# (yeoman-computer.mod.nix), and can start a task:
# a turn of its own with no clock on it, run on the tick, for work that
# outlives the message. Each has a site, `<n>.<domain>` on the tailnet
# proxy: `show_page` writes a page of HTML there and hands back its link.
# With `web` set the yeoman serves that host itself, its chat at the root.
# Assistants in one of `sites` share a host instead: the page's `persona`
# cookie picks which one nginx sends it to, one sign-in serves them all,
# and each one's pages sit under /<unit>/.
# With `homeTokenFile` set, both reach Home Assistant's own MCP server as
# well, its tools withheld on quoted turns like the rest that act. An
# instance with `fastmailTokenFile` reaches its person's Fastmail (mail,
# calendar, contacts) through Fastmail's own MCP server the same way.
#
# The instances share a household directory their common group can write:
# shared lists, and a mailbox each. A message goes only to those it names,
# one or several: an assistant by its name, or a person by theirs, which
# reaches the assistant that is their door. "Tell Gab ..." leaves a message
# in her door's mailbox, and it passes it on in its own words; sharing a
# list, routine or watch leaves one with each named. There is no sending to
# everyone. Memories stay apart; only what is handed over crosses. The
# ship's seat is in the household as Bridge: `tell` from the seat leaves a
# note an instance drains on its tick, marked as the engineer's, and an
# instance's `tell` to Bridge appends to `seat/inbox`, which the seat's
# sessions load as a rule and `inbox` prints.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.yeoman;
  flake.nixosModules.yeoman =
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
        optionals
        length
        head
        elem
        findFirst
        concatMap
        ;
      inherit (lib.meta) getExe;
      inherit (lib.strings)
        readFile
        concatStringsSep
        concatMapStringsSep
        toSentenceCase
        ;
      inherit (lib.options) mkOption;
      inherit (lib.attrsets)
        optionalAttrs
        attrNames
        filterAttrs
        mapAttrs
        mapAttrs'
        mapAttrsToList
        nameValuePair
        ;
      inherit (lib.modules) mkIf mkMerge;
      inherit (lib) types;
      inherit (lib.ship)
        browsers
        fences
        computers
        topology
        ;

      cfg = config.yeoman;

      house = topology.household;
      # The assistants' sites: a directory each, read by nginx as its group.
      pages = "/var/lib/yeoman-pages";
      # Each shared site's sign-ins, in a directory its assistants' group owns.
      sitesDir = "/var/lib/yeoman-sites";
      # After the seat's: an assistant's browser follows its runner's index.
      browserIndex = n: 10 + (computers.indexes cfg.instances).${n};
      siteOf = n: findFirst (s: elem n cfg.sites.${s}.members) null (attrNames cfg.sites);
      host = sub: "https://${sub}.${config.shipProxy.domain}";
      # Who is in the household, as house.rs reads it: unit=Name=Person, and
      # =door on the one a message to the person goes to.
      households = {
        YEOMAN_HOUSE = house;
        YEOMAN_MEMBERS = concatStringsSep "," (
          mapAttrsToList (
            n: i: "${n}=${i.name}=${i.person}${lib.strings.optionalString i.door "=door"}"
          ) cfg.instances
        );
        # The ship's seat is in the household by this name (house.rs).
        YEOMAN_SEAT = "Bridge";
      };

      # The seat's side of the household: `tell NAME TEXT` leaves a note for
      # an assistant, `inbox` prints the assistants' notes to the seat (also
      # loaded into its sessions as a rule), `inbox clear` empties it.
      tell = pkgs.writeShellApplication {
        name = "tell";
        runtimeInputs = singleton yeoman;
        text = ''
          export YEOMAN_HOUSE=${house} YEOMAN_MEMBERS=${lib.strings.escapeShellArg households.YEOMAN_MEMBERS}
          exec yeoman tell "$@"
        '';
      };
      inbox = pkgs.writeShellApplication {
        name = "inbox";
        runtimeInputs = singleton pkgs.coreutils;
        text = ''
          if [ "''${1-}" = clear ]; then
            : > ${house}/seat/inbox
          else
            cat ${house}/seat/inbox
          fi
        '';
      };

      yeoman = lib.ship.rustTool pkgs { src = ./yeoman; };
      hippo = lib.ship.rustTool pkgs { src = ./seat/hippo; };

      # Each web chat's port, after the doors, by sorted name.
      chatPort = n: 8950 + lib.lists.findFirstIndex (m: m == n) 0 (attrNames cfg.instances) + 1;
      # The loopback port of an instance's own OpenCode server.
      openCodePort = n: chatPort n + 100;

      # The web chat's page, built once and served by each assistant.
      web = pkgs.buildNpmPackage {
        pname = "yeoman-site";
        version = "0";
        src = ./yeoman/site;
        npmDepsHash = "sha256-up5No3KEeil1Qw2s38eQR/FugCZFh/Bxs5Bg4C8qulc=";
        # rolldown and tsgo ship prebuilt Linux binaries.
        nativeBuildInputs = [
          pkgs.autoPatchelfHook
          pkgs.resvg
        ];
        buildInputs = singleton pkgs.stdenv.cc.cc.lib;
        # Home screens want the icon as PNG at these sizes.
        installPhase = ''
          cp -r dist $out
          for s in 180 192 512; do
            resvg -w $s -h $s public/_site/icon.svg $out/_site/icon-$s.png
          done
        '';
      };

      image = pkgs.writers.writePython3Bin "yeoman-image-mcp" {
        libraries = singleton pkgs.python3Packages.mcp;
        flakeIgnore = singleton "E501";
      } (readFile ./yeoman-image.py);

      # One connection, one picture: the description on stdin, the PNG out.
      # Codex keeps each thread's pictures under its thread id.
      draw = pkgs.writeShellApplication {
        name = "yeoman-image";
        runtimeInputs = [
          pkgs.codex
          pkgs.jq
          pkgs.coreutils
        ];
        text = ''
          description=$(head -c 4000)
          model=gpt-6-luna
          cd "$(mktemp -d)"
          out=$(timeout 300 codex exec --skip-git-repo-check --ephemeral \
            --ignore-user-config --ignore-rules -s read-only \
            -m "$model" -c model_reasoning_effort=low --json \
            "Make exactly one picture with your image tool from the description below, then answer only: done.

          $description" < /dev/null)
          # One journal line per picture, where `usage` counts the
          # household's share of the subscription.
          jq -rR --arg m "$model" 'fromjson? | select(.type == "turn.completed") | .usage
            | "yeoman-image: tokens model=\($m) input=\(.input_tokens - .cached_input_tokens) cache_read=\(.cached_input_tokens) cache_write=0 output=\(.output_tokens)"' <<< "$out" >&2
          id=$(jq -rR 'fromjson? | select(.type == "thread.started") | .thread_id' <<< "$out" | head -1)
          [ -n "$id" ] || exit 1
          dir="$CODEX_HOME/generated_images/$id"
          trap 'rm -rf "$dir"' EXIT
          for f in "$dir"/*.png; do
            cat "$f"
            exit 0
          done
          exit 1
        '';
      };

      # The token or key rides a systemd credential into the environment,
      # never the command line. An instance with its own API key bills to
      # it; the rest share the subscription token.
      claude = pkgs.writeShellApplication {
        name = "yeoman-claude";
        text = ''
          if [ -e "$CREDENTIALS_DIRECTORY/claude-key" ]; then
            ANTHROPIC_API_KEY=$(< "$CREDENTIALS_DIRECTORY/claude-key")
            export ANTHROPIC_API_KEY
          else
            CLAUDE_CODE_OAUTH_TOKEN=$(< "$CREDENTIALS_DIRECTORY/claude-token")
            export CLAUDE_CODE_OAUTH_TOKEN
          fi
          exec ${getExe pkgs.claude-code} "$@"
        '';
      };

      # Hides the host's managed settings and MCP servers (the seat's), which
      # would forbid --strict-mcp-config.
      claudeEtc = pkgs.writeTextDir "managed-settings.json" "{}";

      # Idempotent: logs in first, else walks the registration-token flow.
      register = pkgs.writeShellApplication {
        name = "yeoman-register";
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
          # A development instance runs whatever build its link points at.
          yeomanBin = if i.build == null then getExe yeoman else "${i.build}/bin/yeoman";
          hippoBin = if i.build == null then getExe hippo else "${i.build}/bin/hippo";
          siteRoot = if i.build == null then web else "${i.build}/site";
          creds = "/run/credentials/${n}.service";
          env = {
            HOME = state;
            HIPPO_DIR = "${state}/hippo";
          };
          # The assistant's computer (yeoman-computer.mod.nix), if it has one.
          pc = optionalAttrs i.computer {
            addr = computers.addr (computers.indexes cfg.instances).${n};
            desk = "${computers.desks}/${n}";
            browser = browsers.addr (browserIndex n);
          };
          # The assistant's site: pages it writes, served by the proxy.
          shared' = siteOf n;
          site = {
            dir = "${pages}/${n}";
            url = if shared' == null then host n else "${host shared'}/${n}";
          };
          shared =
            households
            // {
              YEOMAN_UNIT = n;
              YEOMAN_USAGE = "/run/usage.sock";
              YEOMAN_X = "/run/yeoman-x.sock";
              YEOMAN_PAGES = site.dir;
              YEOMAN_PAGES_URL = site.url;
            }
            // optionalAttrs i.computer {
              YEOMAN_DESK = browsers.desk n;
              YEOMAN_KEEP = "http://${pc.browser}:${toString browsers.keepPort}";
              YEOMAN_RUN = "http://${pc.addr}:${toString computers.runPort}";
              YEOMAN_RUNS = pc.desk;
              YEOMAN_SCREEN = "${host "${n}-screen"}/vnc.html?autoconnect=1&resize=scale&show_dot=1";
              YEOMAN_SCREEN_SIZE = browsers.screen;
            }
            // optionalAttrs (cfg.homeTokenFile != null) { YEOMAN_HOME = "1"; }
            // optionalAttrs (cfg.searchKeyFile != null) { YEOMAN_SEARCH_KEY = "${creds}/search"; }
            // optionalAttrs (i.newsKeyFile != null) {
              YEOMAN_NEWS = "${creds}/news";
              YEOMAN_MINIFLUX = "http://127.0.0.1:${toString config.shipProxy.routes.news.port}";
            }
            // optionalAttrs (cfg.requestsKeyFile != null) {
              YEOMAN_REQUESTS = "${creds}/requests";
              YEOMAN_SEERR = "http://127.0.0.1:${toString config.shipProxy.routes.q.port}";
            };

          mcp = (pkgs.formats.json { }).generate "${n}-mcp.json" {
            mcpServers = {
              yeoman = {
                type = "stdio";
                command = yeomanBin;
                args = [
                  "tools"
                  state
                ];
                env =
                  shared
                  // {
                    inherit (env) HIPPO_DIR;
                    YEOMAN_TZ = config.time.timeZone;
                    YEOMAN_YTDLP = getExe pkgs.yt-dlp;
                  }
                  // optionalAttrs (cfg.weather != null) {
                    YEOMAN_WEATHER = cfg.weather;
                  }
                  // optionalAttrs (cfg.financeDb != null) {
                    YEOMAN_FINANCE = cfg.financeDb;
                  }
                  // optionalAttrs i.money {
                    YEOMAN_MONEY = "/run/money.sock";
                  }
                  // optionalAttrs (i.fastmailTokenFile != null) {
                    YEOMAN_FASTMAIL = "${creds}/fastmail";
                  };
              };
              image = {
                type = "stdio";
                command = getExe image;
                args = singleton "${state}/outbox";
              };
            }
            // optionalAttrs i.computer {
              # Playwright MCP, driving its browser on the host.
              computer = {
                type = "http";
                url = "http://${pc.browser}:${toString browsers.mcpPort}/mcp";
              };
            }
            // optionalAttrs (cfg.homeTokenFile != null) {
              # Home Assistant's own MCP server; the token is filled in at
              # unit start from the credential, into a copy of this file.
              home = {
                type = "http";
                url = "http://127.0.0.1:${toString config.shipProxy.routes.ha.port}/api/mcp";
                headers.Authorization = "Bearer @HOME_TOKEN@";
              };
            }
            // optionalAttrs (i.fastmailTokenFile != null) {
              fastmail = {
                type = "http";
                url = "https://api.fastmail.com/mcp";
                headers.Authorization = "Bearer @FASTMAIL_TOKEN@";
              };
            };
          };

          # With a token in the MCP file, a private copy is made in the
          # runtime directory and the bot pointed at it.
          tokens =
            optional (cfg.homeTokenFile != null) {
              mark = "HOME_TOKEN";
              credential = "home";
            }
            ++ optional (i.fastmailTokenFile != null) {
              mark = "FASTMAIL_TOKEN";
              credential = "fastmail";
            };
          substitute =
            t: "-e \"s|@${t.mark}@|$(tr -d '\\r\\n' < \"$CREDENTIALS_DIRECTORY/${t.credential}\")|\"";
          start =
            if tokens == [ ] then
              yeomanBin
            else
              getExe (
                pkgs.writeShellApplication {
                  name = "${n}-start";
                  runtimeInputs = [
                    pkgs.coreutils
                    pkgs.gnused
                  ];
                  text = ''
                    umask 077
                    sed ${concatStringsSep " " (map substitute tokens)} ${mcp} > "$RUNTIME_DIRECTORY/mcp.json"
                    YEOMAN_MCP="$RUNTIME_DIRECTORY/mcp.json" exec ${yeomanBin}
                  '';
                }
              );

          sandbox = lib.ship.hardened.tenant // {
            User = n;
            Group = n;
            SupplementaryGroups = [
              "yeoman-image"
              "yeoman-x"
              "yeoman-household"
              "usage"
            ]
            # Read access to the money service's finance.db, not its vault.
            ++ lib.lists.optional (cfg.financeDb != null) "finance"
            # And the money service's socket, to change them.
            ++ lib.lists.optional i.money "money";
            StateDirectory = n;
            StateDirectoryMode = "0700";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
          };

          # Each claude call writes its state under HOME.
          claudeCredential =
            if i.claudeKeyFile != null then
              "claude-key:${i.claudeKeyFile}"
            else
              "claude-token:${cfg.claudeTokenFile}";
          claudeUnit = {
            LoadCredential = claudeCredential;
            BindReadOnlyPaths = singleton "${claudeEtc}:/etc/claude-code";
          };
          seat = topology.seat;
          # Matrix only with an account: without one, the site alone.
          matrix = i.credentialsEnvFile != null;
          models =
            optionalAttrs (i.models != [ ]) { YEOMAN_MODELS = concatStringsSep "," i.models; }
            // optionalAttrs (i.efforts != [ ]) { YEOMAN_EFFORTS = concatStringsSep "," i.efforts; };
          forget = optionalAttrs (i.forgetAfter != null) { YEOMAN_FORGET = toString i.forgetAfter; };
          # OpenCode and omp on the host's provider keys, as the seat has
          # them: each harness reads the keys from its own config, so the
          # yeoman holds none.
          keys = {
            keyFile = config.secrets.opencode-key.path;
            deepseekKeyFile = config.secrets.deepseek-key.path;
            abliterationKeyFile = config.secrets.abliteration-key.path;
          };
          openCodeConfig = pkgs.writeText "${n}-opencode.json" (
            lib.strings.toJSON {
              "$schema" = "https://opencode.ai/config.json";
              provider = lib.ship.opencode.providers keys;
            }
          );
          ompModels = pkgs.writeText "${n}-omp-models.yml" (lib.ship.opencode.ompModels keys);
          # omp reads its providers only from its home.
          linkOmpModels = pkgs.writeShellScript "${n}-omp-models" ''
            ${pkgs.coreutils}/bin/mkdir -p ${state}/.omp/agent
            ${pkgs.coreutils}/bin/ln -sfn ${ompModels} ${state}/.omp/agent/models.yml
          '';
        in
        if i.seat then
          {
            # The seat itself behind the yeoman's site: Claude Code as
            # Bridge runs it, with the seat's login, rules, memory and
            # privileges, as paseo does. hippo's watcher keeps its turns.
            ${n} = {
              description = "Bridge in ${i.person}'s web chat (${i.name})";
              wantedBy = singleton "multi-user.target";
              after = singleton "hippo.service";
              wants = singleton "hippo.service";
              environment =
                shared
                // {
                  HOME = seat.home;
                  HIPPO_DIR = seat.hippo;
                  # The seat's own installs, its claude among them.
                  PATH = lib.mkForce (
                    concatStringsSep ":" [
                      "${seat.home}/.nix-profile/bin"
                      "/etc/profiles/per-user/${seat.user}/bin"
                      "/run/wrappers/bin"
                      "/run/current-system/sw/bin"
                    ]
                  );
                  YEOMAN_NAME = i.name;
                  YEOMAN_PERSON = i.person;
                  YEOMAN_BACKEND = "claude";
                  YEOMAN_CLAUDE = "claude";
                  YEOMAN_MODEL = cfg.model;
                  YEOMAN_SEAT_MODE = "1";
                  YEOMAN_SITE = "127.0.0.1:${toString (chatPort n)}";
                  YEOMAN_SITE_ROOT = siteRoot;
                  YEOMAN_SITE_URL = host (if shared' == null then n else shared');
                }
                // optionalAttrs (shared' != null) {
                  YEOMAN_PERSONAS = concatStringsSep "," (
                    map (m: "${m}=${cfg.instances.${m}.name}") cfg.sites.${shared'}.members
                  );
                  YEOMAN_APP = cfg.sites.${shared'}.name;
                  YEOMAN_SESSIONS = "${sitesDir}/${shared'}/sessions";
                }
                // optionalAttrs (i.voice != null) { YEOMAN_VOICE = i.voice; }
                // models;
              serviceConfig = {
                User = seat.user;
                Group = seat.user;
                SupplementaryGroups = [
                  "yeoman-x"
                  "usage"
                ]
                ++ optional (shared' != null) "yeoman-${shared'}";
                StateDirectory = n;
                StateDirectoryMode = "0700";
                WorkingDirectory = seat.home;
                ExecStart = yeomanBin;
                # A restart ends the turn under way; the next message
                # starts afresh from the memory.
                Restart = "always";
                RestartSec = 10;
                # Each turn's claude and what it runs; paseo's bound.
                MemoryHigh = "12G";
              };
            };
          }
        else
          {
            "${n}-register" = mkIf matrix {
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

            # The memory's door, after the seat's on 8940, by sorted name.
            "${n}-door" = mkIf (i.doorPassphraseFile != null) (
              lib.ship.hippoDoor {
                inherit hippo;
                service = "${n}-hippo.service";
                dir = env.HIPPO_DIR;
                user = n;
                agent = i.name;
                inherit (i) person;
                port = 8940 + lib.lists.findFirstIndex (m: m == n) 0 (attrNames cfg.instances) + 1;
                host = "hippo-${n}.${config.shipProxy.domain}";
                passphraseFile = i.doorPassphraseFile;
              }
            );

            "${n}-hippo" = {
              description = "${i.name}'s memory";
              wantedBy = singleton "multi-user.target";
              environment =
                env
                // {
                  HIPPO_AGENT = i.name;
                  HIPPO_VIEW = toString cfg.viewBytes;
                }
                // (
                  if i.localModel != null then
                    {
                      # A local agent's memory stays local too: what it is told
                      # never leaves the host, and its compactor never refuses.
                      HIPPO_BACKEND = "http";
                      HIPPO_URL = "http://127.0.0.1:${toString config.inference.port}/v1";
                      HIPPO_MODEL = i.localModel;
                      # Its template thinks at xhigh by default: ~3x slower than
                      # low for lines about as good on six real jobs, and Azula's
                      # replies queue behind it on the one GPU slot.
                      HIPPO_HTTP_EXTRA = lib.strings.toJSON { chat_template_kwargs.reasoning_effort = "low"; };
                    }
                  else
                    {
                      HIPPO_BACKEND = "claude";
                      HIPPO_CLAUDE = getExe claude;
                      HIPPO_MODEL = "haiku";
                      HIPPO_EFFORT = "high";
                    }
                );
              serviceConfig =
                sandbox
                // fence
                // claudeUnit
                // {
                  StateDirectory = [
                    n
                    "${n}/hippo"
                  ];
                  ExecStart = "${hippoBin} serve chat";
                  Restart = "always";
                  RestartSec = 5;
                };
            };

            ${n} = {
              description = "${i.name}, ${i.person}'s household assistant";
              wantedBy = singleton "multi-user.target";
              wants = [
                "${n}-hippo.service"
              ]
              ++ optionals matrix [
                "tuwunel.service"
                "${n}-register.service"
              ];
              after = [
                "${n}-hippo.service"
              ]
              ++ optionals matrix [
                "tuwunel.service"
                "${n}-register.service"
              ];
              environment =
                env
                // shared
                // {
                  YEOMAN_NAME = i.name;
                  YEOMAN_PERSON = i.person;
                  YEOMAN_BACKEND = "claude";
                  YEOMAN_CLAUDE = getExe claude;
                  YEOMAN_MODEL = cfg.model;
                  YEOMAN_MCP = toString mcp;
                }
                // models
                // forget
                // optionalAttrs matrix {
                  YEOMAN_HOMESERVER = "http://127.0.0.1:${toString config.matrix.port}";
                  YEOMAN_USERS = concatStringsSep "," i.users;
                  YEOMAN_MATRIX = "${creds}/matrix";
                }
                // optionalAttrs (i.localModel != null) {
                  # Local inference takes no MCP, so it answers without tools.
                  YEOMAN_BACKEND = "http";
                  YEOMAN_URL = "http://127.0.0.1:${toString config.inference.port}/v1";
                  YEOMAN_MODEL = i.localModel;
                }
                // optionalAttrs i.providerKeys {
                  OPENCODE_CONFIG = toString openCodeConfig;
                  YEOMAN_OPENCODE_PORT = toString (openCodePort n);
                }
                // optionalAttrs (i.style != null) { YEOMAN_STYLE = i.style; }
                // optionalAttrs (i.voice != null) { YEOMAN_VOICE = i.voice; }
                // optionalAttrs i.web {
                  YEOMAN_SITE = "127.0.0.1:${toString (chatPort n)}";
                  YEOMAN_SITE_ROOT = siteRoot;
                  # Names this server to push services, and the site to its
                  # notifications.
                  YEOMAN_SITE_URL = host (if shared' == null then n else shared');
                }
                // optionalAttrs (shared' != null) {
                  YEOMAN_PERSONAS = concatStringsSep "," (
                    map (m: "${m}=${cfg.instances.${m}.name}") cfg.sites.${shared'}.members
                  );
                  YEOMAN_APP = cfg.sites.${shared'}.name;
                  YEOMAN_SESSIONS = "${sitesDir}/${shared'}/sessions";
                }
                // optionalAttrs i.alerts { YEOMAN_ALERTS = config.alerts.spool; }
                # Watches read the money here, not in the tools.
                // {
                  YEOMAN_TZ = config.time.timeZone;
                }
                // optionalAttrs (cfg.financeDb != null) {
                  YEOMAN_FINANCE = cfg.financeDb;
                }
                # Its own Fastmail calls: the send barring at start, then
                # the watches and approved drafts.
                // optionalAttrs (i.fastmailTokenFile != null) {
                  YEOMAN_FASTMAIL = "${creds}/fastmail";
                };
              serviceConfig =
                sandbox
                // fence
                // claudeUnit
                // {
                  ExecStart = start;
                  LoadCredential = [
                    claudeCredential
                  ]
                  ++ optional matrix "matrix:${i.credentialsEnvFile}"
                  ++ optional (i.newsKeyFile != null) "news:${i.newsKeyFile}"
                  ++ optional (cfg.homeTokenFile != null) "home:${cfg.homeTokenFile}"
                  ++ optional (i.fastmailTokenFile != null) "fastmail:${i.fastmailTokenFile}"
                  ++ optional (cfg.requestsKeyFile != null) "requests:${cfg.requestsKeyFile}"
                  ++ optional (cfg.searchKeyFile != null) "search:${cfg.searchKeyFile}";
                  RuntimeDirectory = n;
                  RuntimeDirectoryMode = "0700";
                  Restart = "always";
                  RestartSec = 10;
                  ReadWritePaths = [
                    site.dir
                    house
                  ]
                  ++ optional i.alerts config.alerts.spool
                  ++ optionals i.computer [
                    pc.desk
                    (browsers.desk n)
                  ]
                  ++ optional (shared' != null) "${sitesDir}/${shared'}";
                }
                // optionalAttrs (i.web || i.providerKeys) {
                  SocketBindAllow =
                    optional i.web "tcp:${toString (chatPort n)}"
                    ++ optional i.providerKeys "tcp:${toString (openCodePort n)}";
                }
                // optionalAttrs (i.computer || shared' != null || i.providerKeys) {
                  SupplementaryGroups =
                    sandbox.SupplementaryGroups
                    ++ optional i.computer computers.deskGroup
                    ++ optional (shared' != null) "yeoman-${shared'}"
                    ++ optional i.providerKeys "opencode-auth";
                }
                // optionalAttrs i.providerKeys { ExecStartPre = linkOmpModels; }
                // optionalAttrs i.computer {
                  # Through the fence to its own runner and browser.
                  IPAddressAllow = fence.IPAddressAllow ++ [
                    pc.addr
                    pc.browser
                  ];
                };
            };

          };

      alerted = attrNames (filterAttrs (_: i: i.alerts) cfg.instances);
      # The instances that run as a user of their own: all but the seat's.
      ownUsers = filterAttrs (_: i: !i.seat) cfg.instances;
      built = filterAttrs (_: i: i.build != null) cfg.instances;
      inSites = concatMap (s: cfg.sites.${s}.members) (attrNames cfg.sites);
    in
    {
      options.yeoman = {
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
                    default = [ ];
                    example = singleton "@alice:chat.example.com";
                    description = ''
                      Who it talks with: it joins rooms they invite it to and
                      answers only them.
                    '';
                  };

                  credentialsEnvFile = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = ''
                      Required unless seat is on.
                      agenix env file with MATRIX_USER=@name:server and
                      MATRIX_PASSWORD=..., the assistant's own Matrix
                      account, registered on first start.
                    '';
                  };

                  fastmailTokenFile = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = ''
                      agenix file holding the person's Fastmail MCP API
                      token, whose scopes Fastmail enforces; null for no
                      Fastmail.
                    '';
                  };

                  newsKeyFile = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = ''
                      File holding a Miniflux API key, raw (news.apiKeys makes one), for the
                      person's feed reader (news.mod.nix); null for none.
                    '';
                  };

                  style = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "Be a little warm.";
                    description = "A line on tone, added to the prompt.";
                  };

                  web = mkOption {
                    type = types.bool;
                    default = false;
                    description = ''
                      Whether it serves a web chat at the root of its site,
                      <name>.<domain> on the tailnet, beside its pages;
                      sign-in codes are approved in its Matrix room.
                    '';
                  };

                  alerts = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Whether it posts the host's alerts.";
                  };

                  money = mkOption {
                    type = types.bool;
                    default = false;
                    description = ''
                      Whether it may change the household's money records
                      (categories, budget lines, hand-kept accounts) through
                      the money service's socket; reading needs only financeDb.
                    '';
                  };

                  claudeKeyFile = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = ''
                      Claude API key for this instance's model calls and
                      memory, billed to the key's Console organization.
                      null = the shared subscription token
                      (claudeTokenFile).
                    '';
                  };

                  localModel = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "qwen3.8-27b-q4-k-m";
                    description = ''
                      A model of the local inference server (inference.mod.nix)
                      to answer and condense its memory with, without tools;
                      null = Claude.
                    '';
                  };

                  voice = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "eve";
                    description = ''
                      The xAI voice the site reads replies aloud in, through
                      yeoman-x's sign-in; null = no read-aloud button.
                    '';
                  };

                  models = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [
                      "opus"
                      "sonnet"
                    ];
                    description = ''
                      Claude models the person may switch between in the web
                      chat's settings; empty keeps the model fixed.
                    '';
                  };

                  efforts = mkOption {
                    type = types.listOf (
                      types.enum [
                        "low"
                        "medium"
                        "high"
                        "xhigh"
                        "max"
                      ]
                    );
                    default = [ ];
                    example = [
                      "low"
                      "high"
                    ];
                    description = ''
                      Thinking efforts (`claude --effort`) the person may
                      switch between in the web chat's settings; empty keeps
                      the CLI's default.
                    '';
                  };

                  forgetAfter = mkOption {
                    type = types.nullOr types.ints.positive;
                    default = null;
                    example = 60;
                    description = ''
                      Minutes it remembers, until the person picks another
                      window in the web chat: every minute, older messages,
                      files and pages go, oldest first; null = never.
                    '';
                  };

                  door = mkOption {
                    type = types.bool;
                    default = true;
                    description = ''
                      Whether it is its person's door: a message or share
                      sent to the person by name reaches this assistant.
                      One per person; every assistant has its own mailbox
                      either way, reached by its name.
                    '';
                  };

                  build = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "/var/lib/libri-build/current";
                    description = ''
                      A link to a development build (bin/yeoman, bin/hippo,
                      site/) to run instead of the ship's own. The seat may
                      restart the instance's units, so a rebuild needs no
                      deploy.
                    '';
                  };

                  providerKeys = mkOption {
                    type = types.bool;
                    default = false;
                    description = ''
                      Whether OpenCode and omp reach the host's model
                      providers (OpenCode Zen and Go, DeepSeek,
                      abliteration.ai): the instance reads the opencode-auth
                      keys, each harness's config names them, and OpenCode's
                      server gets a loopback port.
                    '';
                  };

                  seat = mkOption {
                    type = types.bool;
                    default = false;
                    description = ''
                      Whether this is the seat itself in a web chat: each
                      message runs Claude Code as the seat user, with its
                      settings, hooks, MCP servers, built-in tools and
                      memory; no Matrix, sandbox or memory of its own.
                    '';
                  };

                  doorPassphraseFile = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = ''
                      Passphrase for its memory's door (lib/hippo-door.nix),
                      hippo-<name>.<domain>, 12 characters or more; the
                      hippo tunnel carries it. null = no door.
                    '';
                  };
                };
              }
            )
          );
        };

        sites = mkOption {
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  name = mkOption {
                    type = types.str;
                    default = toSentenceCase name;
                    description = "What the site and its installed app are called.";
                  };

                  members = mkOption {
                    type = types.listOf types.str;
                    description = ''
                      Its assistants, each with web on; the first answers by
                      default and takes the sign-ins, in its Matrix room.
                    '';
                  };
                };
              }
            )
          );
          default = { };
          example.si = {
            name = "Home";
            members = [
              "alice"
              "bob"
            ];
          };
          description = ''
            Web chats shared by several assistants, by host label: each
            member answers at <label>.<domain> when the page picks it.
          '';
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

        homeTokenFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            agenix file holding a Home Assistant long-lived access token,
            for its MCP server; shared by the instances. Null leaves the
            home out.
          '';
        };

        searchKeyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            agenix file holding a Parallel account API key, raw, which lifts
            web search from the keyless rate limit; shared by the instances.
            Null searches keyless.
          '';
        };

        requestsKeyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            agenix file holding Seerr's API key, raw, for requesting films
            and shows; shared by the instances. Null leaves requests out.
          '';
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

        weather = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "43.07,-70.76";
          description = ''
            `latitude,longitude` for the forecast the weather tool reads
            from Open-Meteo; shared by the instances. Null leaves it out.
          '';
        };

        financeDb = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/var/lib/money/production/finance.db";
          description = ''
            The money service's finance.db, which the finance tool reads
            through the `finance` group; shared by the instances. Null
            leaves it out.
          '';
        };
      };

      config = {
        assertions = [
          {
            assertion = length alerted <= 1;
            message = "yeoman: only one instance can take the alerts.";
          }
          {
            assertion = lib.lists.all (n: cfg.instances ? ${n} && cfg.instances.${n}.web) inSites;
            message = "yeoman: a site lists only instances with web on.";
          }
          {
            assertion = lib.lists.all (
              i: (i.credentialsEnvFile != null || i.web) && !(i.seat && i.forgetAfter != null)
            ) (lib.attrsets.attrValues cfg.instances);
            message = "yeoman: an instance needs Matrix or web on, and the seat can't forget.";
          }
          {
            assertion = lib.lists.allUnique (
              mapAttrsToList (_: i: i.person) (filterAttrs (_: i: i.door) cfg.instances)
            );
            message = "yeoman: a person has one door at most.";
          }
          {
            # A seat instance is Bridge itself, so it alone may bear the name;
            # the household sends notes for Bridge to the seat's inbox.
            assertion = lib.lists.allUnique (
              [ "bridge" ]
              ++ mapAttrsToList (_: i: lib.strings.toLower i.name) (filterAttrs (_: i: !i.seat) cfg.instances)
            );
            message = "yeoman: assistants need different names, none of them Bridge.";
          }
          {
            assertion = lib.lists.allUnique inSites;
            message = "yeoman: an instance belongs to one site at most.";
          }
        ];

        # The seat's agents, for the claude runs a seat instance starts: the
        # yeoman names its state in YEOMAN_AGENTS, and any other claude on the
        # seat (paseo's) finds no tools here.
        seat.claudeMcp = mkIf (lib.lists.any (i: i.seat) (lib.attrsets.attrValues cfg.instances)) {
          yeoman = {
            type = "stdio";
            command = getExe yeoman;
            args = singleton "agents";
            # Four small tools the seat always needs: load them up front, so
            # its first spawn of a turn isn't a schemaless call that fails.
            alwaysLoad = true;
          };
        };

        ship.browsers = mapAttrs' (
          n: _:
          nameValuePair n {
            index = browserIndex n;
            users = singleton n;
          }
        ) (filterAttrs (_: i: i.computer) cfg.instances);

        # Sensors and the receiver write alerts in as root or the reader;
        # nobody else may, since what it posts its memory keeps.
        alerts.reader = mkIf (alerted != [ ]) (head alerted);

        # yeoman-image holds the household's one Codex login, on the ChatGPT
        # subscription; the assistants reach only its socket. Log in once,
        # with the codex from the unit's script (not on PATH), after
        # `sudo install -d -o yeoman-image -g yeoman-image -m 700 /var/lib/yeoman-image`:
        # sudo -u yeoman-image env HOME=/var/lib/yeoman-image CODEX_HOME=/var/lib/yeoman-image <codex> login --device-auth
        # yeoman-x holds the xAI sign-in the same way; once, after
        # `sudo install -d -o yeoman-x -g yeoman-x -m 700 /var/lib/yeoman-x`:
        # sudo -u yeoman-x env HOME=/var/lib/yeoman-x <yeoman> x login
        users.users =
          mapAttrs
            (n: _: {
              isSystemUser = true;
              group = n;
              home = "/var/lib/${n}";
            })
            (
              ownUsers
              // {
                yeoman-image = { };
                yeoman-x = { };
              }
            )
          // {
            # The seat reads and writes the household's seat/ files as the group.
            ${topology.seat.user}.extraGroups = singleton "yeoman-household";
          };
        users.groups =
          mapAttrs (_: _: { }) ownUsers
          // lib.attrsets.mapAttrs' (s: _: nameValuePair "yeoman-${s}" { }) cfg.sites
          // {
            yeoman-image = { };
            yeoman-x = { };
            yeoman-household = { };
          };
        environment.systemPackages = [
          tell
          inbox
        ];

        # Each assistant's pages at https://<n>.<domain>/<page>/, for the
        # tailnet like every other route. With a web chat the yeoman serves
        # the host itself: the chat at the root, the pages beside it.
        shipProxy.routes =
          (
            cfg.instances
            |> filterAttrs (n: _: !(elem n inSites))
            |> mapAttrs (
              n: i:
              if i.web then
                {
                  port = chatPort n;
                  # Server-sent events stream as they come; uploads may be
                  # as big as the chat takes (UPLOAD_MAX in site.rs).
                  proxyExtra = "proxy_buffering off; client_max_body_size 100m;";
                }
              else
                { root = "${pages}/${n}"; }
            )
          )
          // mapAttrs (s: site: {
            port = chatPort (head site.members);
            upstream = "http://$yeoman_${s}";
            proxyExtra = "proxy_buffering off; client_max_body_size 100m;";
          }) cfg.sites;

        # The persona cookie names a unit; anything else gets the first.
        services.nginx.appendHttpConfig =
          cfg.sites
          |> mapAttrsToList (
            s: site: ''
              map $cookie_persona $yeoman_${s} {
                default 127.0.0.1:${toString (chatPort (head site.members))};
              ${concatStringsSep "\n" (map (m: "  ${m} 127.0.0.1:${toString (chatPort m)};") site.members)}
              }
            ''
          )
          |> concatStringsSep "\n";

        services.nginx.virtualHosts =
          cfg.sites
          |> lib.attrsets.mapAttrs' (
            s: site:
            let
              first = "http://127.0.0.1:${toString (chatPort (head site.members))}";
            in
            nameValuePair "${s}.${config.shipProxy.domain}" {
              locations =
                (
                  site.members
                  # Sandboxed as the yeoman serves them (PAGE_SANDBOX in
                  # site.rs): a page here shares the chat's address.
                  |> map (
                    m:
                    nameValuePair "/${m}/" {
                      alias = "${pages}/${m}/";
                      extraConfig = ''
                        add_header Content-Security-Policy "sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads" always;
                      '';
                    }
                  )
                  |> lib.attrsets.listToAttrs
                )
                # Each at /@<unit>/ besides, the prefix stripped, so the
                # split view can show two at once: the cookie picks only one.
                // (
                  site.members
                  |> map (
                    m:
                    nameValuePair "/@${m}/" {
                      proxyPass = "http://127.0.0.1:${toString (chatPort m)}/";
                      extraConfig = "proxy_buffering off; client_max_body_size 100m;";
                    }
                  )
                  |> lib.attrsets.listToAttrs
                )
                # Sign-in asks in the first one's Matrix room, whichever
                # assistant the page shows; the session it grants is shared.
                // {
                  "= /api/ask".proxyPass = first;
                  "= /api/wait".proxyPass = first;
                  "~ ^/@[^/]+/api/(ask|wait)$".proxyPass = "${first}/api/$1";
                };
            }
          );
        systemd.tmpfiles.settings.yeoman-pages = {
          ${pages}.d = {
            user = "root";
            group = "root";
            mode = "0751";
          };
        }
        // lib.attrsets.mapAttrs' (n: _: {
          name = "${pages}/${n}";
          value.d = {
            user = if cfg.instances.${n}.seat then topology.seat.user else n;
            group = "nginx";
            mode = "2750";
          };
        }) cfg.instances;

        systemd.tmpfiles.settings.yeoman-sites = {
          ${sitesDir}.d = {
            user = "root";
            group = "root";
            mode = "0751";
          };
        }
        // lib.attrsets.mapAttrs' (s: _: {
          name = "${sitesDir}/${s}";
          value.d = {
            user = "root";
            group = "yeoman-${s}";
            mode = "2770";
          };
        }) cfg.sites;

        # A development instance's build link lives in a directory the seat
        # owns, and the seat restarts its units after rebuilding the link.
        systemd.tmpfiles.settings.yeoman-builds = lib.attrsets.mapAttrs' (_: i: {
          name = dirOf i.build;
          value.d = {
            user = topology.seat.user;
            group = topology.seat.user;
            mode = "0755";
          };
        }) built;
        security.polkit.extraConfig = mkIf (built != { }) ''
          polkit.addRule(function (action, subject) {
            if (action.id == "org.freedesktop.systemd1.manage-units" &&
                [${
                  concatMapStringsSep ", " (n: ''"${n}.service", "${n}-hippo.service"'') (attrNames built)
                }].indexOf(action.lookup("unit")) >= 0 &&
                ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0 &&
                subject.user == "${topology.seat.user}") {
              return polkit.Result.YES;
            }
          });
        '';

        # Setgid, so what one assistant writes stays the group's.
        systemd.tmpfiles.settings.yeoman-household = {
          ${house}.d = {
            user = "root";
            group = "yeoman-household";
            mode = "2770";
          };
          "${house}/mail".d = {
            user = "root";
            group = "yeoman-household";
            mode = "2770";
          };
          "${house}/seat".d = {
            user = "root";
            group = "yeoman-household";
            mode = "2770";
          };
          "${house}/seat/inbox".f = {
            user = "root";
            group = "yeoman-household";
            mode = "0660";
          };
        }
        // lib.attrsets.mapAttrs' (n: _: {
          name = "${house}/mail/${n}";
          value.d = {
            user = "root";
            group = "yeoman-household";
            mode = "2770";
          };
        }) cfg.instances
        // lib.attrsets.mapAttrs' (n: _: {
          name = "${house}/seat/${n}";
          value.d = {
            user = "root";
            group = "yeoman-household";
            mode = "2770";
          };
        }) cfg.instances;

        systemd.sockets.yeoman-image = {
          description = "Pictures for the household assistants";
          wantedBy = singleton "sockets.target";
          socketConfig = {
            ListenStream = "/run/yeoman-image.sock";
            Accept = true;
            MaxConnections = 2;
            SocketMode = "0660";
            SocketGroup = "yeoman-image";
          };
        };

        systemd.sockets.yeoman-x = {
          description = "X search for the household assistants";
          wantedBy = singleton "sockets.target";
          socketConfig = {
            ListenStream = "/run/yeoman-x.sock";
            Accept = true;
            MaxConnections = 4;
            SocketMode = "0660";
            SocketGroup = "yeoman-x";
          };
        };

        systemd.services = mkMerge (
          mapAttrsToList services cfg.instances
          ++ singleton {
            "yeoman-image@" = {
              description = "One picture for a household assistant";
              environment = {
                HOME = "/var/lib/yeoman-image";
                CODEX_HOME = "/var/lib/yeoman-image";
              };
              serviceConfig =
                lib.ship.hardened.tenant
                // fence
                // {
                  User = "yeoman-image";
                  Group = "yeoman-image";
                  StateDirectory = "yeoman-image";
                  StateDirectoryMode = "0700";
                  ExecStart = getExe draw;
                  StandardInput = "socket";
                  StandardOutput = "socket";
                  StandardError = "journal";
                  # Hides the seat's Codex config and its MCP servers.
                  BindReadOnlyPaths = singleton "${pkgs.emptyDirectory}:/etc/codex";
                };
            };
            "yeoman-x@" = {
              description = "One X search for a household assistant";
              environment.HOME = "/var/lib/yeoman-x";
              serviceConfig =
                lib.ship.hardened.tenant
                // fence
                // {
                  User = "yeoman-x";
                  Group = "yeoman-x";
                  StateDirectory = "yeoman-x";
                  StateDirectoryMode = "0700";
                  ExecStart = "${getExe yeoman} x";
                  StandardInput = "socket";
                  StandardOutput = "socket";
                  StandardError = "journal";
                };
            };
          }
        );
      };
    };
}
