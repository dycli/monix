# Libri on Water (Libri's nix/module.nix): one assistant per person, each in
# the endless web chat of its own Libri, with its own memory. `libri` is the
# seat itself behind that chat, Bridge for Dylan on the seat's logins, tools
# and hippo. `suki` is Gab's, sandboxed under her own user, with her own hippo
# unit and a computer for code (yeoman-computer.mod.nix). Each runs whatever
# build its link in /var/lib/libri-build points at, so the seat rebuilds
# without a deploy.
#
# All of Libri's settings sit in its config file. The links move on their own
# schedule and Suki's follows the branch `stable`, which reads the same keys
# under the old YEOMAN_ environment names, so this file writes only keys both
# builds know: an unknown key stops a build from starting.
#
# Model calls reach only what the instance's MCP file names. Suki has pictures
# (yeoman-image.py), drawn by the image service, the only assistant-side
# holder of a Codex login, Home Assistant's own MCP server, and Fastmail's.
#
# The instances share a household directory their common group can write:
# shared lists, and a mailbox each. A message goes only to those it names; a
# person's name reaches the assistant that is their door. Memories stay apart.
# The seat is in the household as Bridge: `tell` from the seat leaves a note
# an instance drains on its tick, and an instance's `tell` to Bridge appends
# to `seat/inbox`, which the seat's sessions load as a rule and `inbox` prints.
{ inputs, self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.libri;
  flake.nixosModules.libri =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.strings) readFile concatStringsSep;
      inherit (lib.ship) fences computers topology;

      seat = topology.seat;
      house = topology.household;
      # The assistants' sites: a directory each, read by nginx as its group.
      pages = "/var/lib/yeoman-pages";
      host = sub: "https://${sub}.${config.shipProxy.domain}";

      ports = {
        libri = 8951;
        suki = 8952;
      };
      # Who is in the household, as house.rs reads it: unit=Name=Person, and
      # =door on the one a message to the person goes to.
      members = "libri=Bridge=Dylan=door,suki=Suki=Gab=door";
      # Where each member takes A2A messages (a2a.rs): `seat` is the seat's
      # daily chat.
      peers = "suki=http://127.0.0.1:${toString ports.suki},seat=http://127.0.0.1:${toString ports.libri}";
      # What both configs say alike.
      shared = unit: {
        household = {
          inherit peers unit;
          # The ship's seat is in the household by this name (house.rs).
          seat = "Bridge";
        };
        harness = {
          default = "claude";
          model = "opus";
        };
        tools = {
          home = "1";
          usage = "/run/usage.sock";
          requests = "/run/credentials/${unit}.service/requests";
          seerr = "http://127.0.0.1:${toString config.shipProxy.routes.q.port}";
        };
      };
      site = unit: subdomain: {
        listen = "127.0.0.1:${toString ports.${unit}}";
        url = host subdomain;
        site = "/var/lib/libri-build/${unit}/site";
        pages = "${pages}/${unit}";
        pages_url = host subdomain;
        # The app at libri.su.is talks to it, with no sign-in on the tailnet.
        open = "1";
        origins = "https://libri.su.is";
      };
      # Libri's assistant calls itself Libri; an instance here is itself by
      # this rule text, on every prompt, Temp and calls included.
      identity =
        name: role:
        pkgs.writeText "${lib.strings.toLower name}-identity.md" ''
          You go by ${name}, not Libri: you are ${role}, and wherever these
          instructions say Libri they mean you.
        '';

      # The seat's side of the household: `tell NAME TEXT` leaves a note for
      # an assistant, `inbox` prints the assistants' notes to the seat (also
      # loaded into its sessions as a rule), `inbox clear` empties it.
      tell = pkgs.writeShellApplication {
        name = "tell";
        text = ''
          export LIBRI_HOUSE=${house} LIBRI_MEMBERS=${lib.strings.escapeShellArg members} LIBRI_A2A=${lib.strings.escapeShellArg peers}
          exec ${getExe inputs.libri.packages.${pkgs.stdenv.hostPlatform.system}.daemon} tell "$@"
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

      # The seat's Libri keeps the managed settings (the seat's permissions),
      # without their hooks, which Libri brings itself, and without the MCP
      # list: Claude Code takes no other while one exists, and Libri hands it
      # its own each turn.
      seatClaudeEtc = pkgs.writeTextDir "managed-settings.json" (
        lib.strings.toJSON (lib.attrsets.removeAttrs config.seat.claudeSettings [ "hooks" ])
      );
      # What Libri adds to its own tools on the seat's turns. Fastmail isn't
      # here: Libri's connection relays it, and refuses sending.
      seatMcp = (pkgs.formats.json { }).generate "seat-libri-mcp.json" {
        mcpServers = removeAttrs config.seat.mcpServers [ "fastmail" ];
      };
      # The ship's guide for any harness, as Libri's turns read no rule files.
      seatGuide = pkgs.writeText "seat-libri-guide.md" (
        "You are the ship's engineer.\n\n" + lib.ship.guide.system + lib.ship.guide.engineer
      );
      # OpenCode and omp on the host's provider keys, as the seat has them:
      # each harness reads the keys from its own config, so Libri holds none.
      keys = {
        keyFile = config.secrets.opencode-key.path;
        deepseekKeyFile = config.secrets.deepseek-key.path;
        abliterationKeyFile = config.secrets.abliteration-key.path;
      };
      openCodeConfig = pkgs.writeText "libri-opencode.json" (
        lib.strings.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          provider = lib.ship.opencode.providers keys;
        }
      );
      ompModels = pkgs.writeText "libri-omp-models.yml" (lib.ship.opencode.ompModels keys);
      # omp reads its providers only from its home.
      linkOmpModels = pkgs.writeShellScript "libri-omp-models" ''
        ${pkgs.coreutils}/bin/mkdir -p ${seat.home}/.omp/agent
        ${pkgs.coreutils}/bin/ln -sfn ${ompModels} ${seat.home}/.omp/agent/models.yml
      '';

      suki = "/var/lib/suki";
      sukiDesk = "${computers.desks}/suki";
      # Her tool server, under the name her build gives its own entry. The
      # household stays here, not in her config: her build's wrapper unsets
      # it for the daemon (Libri flake.nix `default`), and only the tools
      # may have it. The entry becomes `libri`, with LIBRI_ names, the day
      # `stable` carries the rename; the daemon passes the rest down itself.
      sukiMcp = (pkgs.formats.json { }).generate "suki-mcp.json" {
        mcpServers = {
          yeoman = {
            type = "stdio";
            command = "/var/lib/libri-build/suki/bin/libri";
            args = [
              "tools"
              suki
            ];
            env = {
              YEOMAN_HOUSE = house;
              YEOMAN_MEMBERS = members;
            };
          };
          image = {
            type = "stdio";
            command = getExe image;
            args = singleton "${suki}/outbox";
          };
          home = {
            type = "http";
            url = "http://127.0.0.1:${toString config.shipProxy.routes.ha.port}/api/mcp";
            headers.Authorization = "Bearer @HOME_TOKEN@";
          };
          fastmail = {
            type = "http";
            url = "https://api.fastmail.com/mcp";
            headers.Authorization = "Bearer @FASTMAIL_TOKEN@";
          };
        };
      };
      # Claude Code bills to the key in its environment. systemd reads the
      # unit's EnvironmentFile between ExecStartPre and ExecStart, so the key
      # rides a credential and never sits in a file past the unit's life.
      claudeKey = pkgs.writeShellScript "claude-key" ''
        umask 077
        printf 'ANTHROPIC_API_KEY=%s\n' "$(< "$CREDENTIALS_DIRECTORY/claude-key")" > "$RUNTIME_DIRECTORY/claude.env"
      '';
      # The tokens rise from their credentials into a private copy of the file.
      sukiMcpTokens = pkgs.writeShellScript "suki-mcp-tokens" ''
        umask 077
        ${pkgs.gnused}/bin/sed \
          -e "s|@HOME_TOKEN@|$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/home")|" \
          -e "s|@FASTMAIL_TOKEN@|$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/fastmail")|" \
          ${sukiMcp} > "$RUNTIME_DIRECTORY/mcp.json"
      '';

      # The homeserver and resolver on loopback, and the internet for the
      # model; not the tailnet, the LAN or the seat's loopback address.
      fence = {
        IPAddressAllow = fences.loopback;
        IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
      };
      sukiSandbox =
        lib.ship.hardened.tenant
        // fence
        // {
          User = "suki";
          Group = "suki";
          SupplementaryGroups = [
            "yeoman-image"
            "yeoman-household"
            "usage"
            # Read access to the money service's finance.db, not its vault.
            "finance"
            # And the money service's socket, to change them.
            "money"
            computers.deskGroup
          ];
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          # Hides the seat's managed settings and MCP servers, which would
          # forbid --strict-mcp-config.
          BindReadOnlyPaths = singleton "${pkgs.writeTextDir "managed-settings.json" "{}"}:/etc/claude-code";
          EnvironmentFile = "-%t/%N/claude.env";
        };
    in
    {
      imports = singleton inputs.libri.nixosModules.default;

      services.libri.instances.libri = {
        package = seat.libriBuild;
        inherit (seat) user;
        settings = lib.recursiveUpdate (shared "libri") {
          name = "Bridge";
          person = "Dylan";
          daemon = site "libri" "si";
          hippo = {
            dir = seat.hippo;
            # The seat's hippo keeps Paseo's and the cockpit's chats too; the
            # title its history already goes under.
            shared = "Bridge";
          };
          harness = {
            mcp = toString seatMcp;
            identity = toString (identity "Bridge" "the ship's engineer");
            instructions = toString seatGuide;
            # Full ids, so the picker can show each model's version.
            models = "claude-opus-5-5,claude-sonnet-5-5,claude-haiku-5-5,claude-fable-5-1";
            efforts = "low,medium,high,xhigh,max";
          };
        };
      };

      services.libri.instances.suki = {
        package = "/var/lib/libri-build/suki";
        harnesses = singleton pkgs.claude-code;
        settings = lib.recursiveUpdate (shared "suki") {
          name = "Suki";
          person = "Gab";
          style = "Gab likes a slightly warmer tone.";
          timezone = config.time.timeZone;
          daemon = site "suki" "suki";
          hippo = {
            dir = "${suki}/hippo";
            # Its compactor is its hippo unit's, not Libri's Settings.
            backend = "claude";
          };
          harness = {
            mcp = "/run/suki/mcp.json";
            identity = toString (identity "Suki" "Gab's household assistant");
            # An assistant: Libri's tools only, no shell or files.
            coding = "0";
          };
          tools = {
            finance = "/var/lib/money/${config.money.environment}/finance.db";
            money = "/run/money.sock";
            # Portsmouth, NH.
            weather = "43.07,-70.76";
            ytdlp = getExe pkgs.yt-dlp;
          };
          computer = {
            run = "http://${computers.addr computers.indexes.suki}:${toString computers.runPort}";
            runs = sukiDesk;
          };
        };
      };

      # yeoman-image holds the household's one Codex login, on the ChatGPT
      # subscription; the assistants reach only its socket. Log in once,
      # with the codex from the unit's script (not on PATH), after
      # `sudo install -d -o yeoman-image -g yeoman-image -m 700 /var/lib/yeoman-image`:
      # sudo -u yeoman-image env HOME=/var/lib/yeoman-image CODEX_HOME=/var/lib/yeoman-image <codex> login --device-auth
      users.users.yeoman-image = {
        isSystemUser = true;
        group = "yeoman-image";
        home = "/var/lib/yeoman-image";
      };
      # The seat reads and writes the household's seat/ files as the group.
      users.users.${seat.user}.extraGroups = singleton "yeoman-household";
      users.groups.yeoman-image = { };
      users.groups.yeoman-household = { };
      environment.systemPackages = [
        tell
        inbox
      ];

      # Each serves its host itself: the chat at the root, the pages beside
      # it. Server-sent events stream as they come; uploads may be as big as
      # the chat takes (UPLOAD_MAX in site.rs).
      shipProxy.routes =
        lib.attrsets.mapAttrs
          (n: subdomain: {
            inherit subdomain;
            port = ports.${n};
            proxyExtra = "proxy_buffering off; client_max_body_size 100m;";
          })
          {
            libri = "si";
            suki = "suki";
          };

      systemd.tmpfiles.settings.yeoman-pages = {
        ${pages}.d = {
          user = "root";
          group = "root";
          mode = "0751";
        };
        "${pages}/libri".d = {
          user = seat.user;
          group = "nginx";
          mode = "2750";
        };
        "${pages}/suki".d = {
          user = "suki";
          group = "nginx";
          mode = "2750";
        };
      };

      # An instance's Libri build link lives in a directory the seat owns,
      # and the seat restarts its units after rebuilding the link.
      systemd.tmpfiles.settings.yeoman-builds."/var/lib/libri-build".d = {
        user = seat.user;
        group = seat.user;
        mode = "0755";
      };
      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              ["hippo.service", "libri.service", "libri-hippo.service", "suki.service", "suki-hippo.service"].indexOf(action.lookup("unit")) >= 0 &&
              ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0 &&
              subject.user == "${seat.user}") {
            return polkit.Result.YES;
          }
        });
      '';

      # Setgid, so what one assistant writes stays the group's.
      systemd.tmpfiles.settings.yeoman-household =
        let
          entry = mode: {
            user = "root";
            group = "yeoman-household";
            inherit mode;
          };
        in
        lib.attrsets.genAttrs
          [
            house
            "${house}/mail"
            "${house}/seat"
            "${house}/mail/libri"
            "${house}/mail/suki"
            "${house}/seat/libri"
            "${house}/seat/suki"
          ]
          (_: {
            d = entry "2770";
          })
        // {
          "${house}/seat/inbox".f = entry "0660";
        };

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

      systemd.services = {
        # The seat itself behind Libri's site: Bridge, on the seat's logins
        # and privileges, so none of the service's defaults apply.
        libri = {
          description = "Bridge in Dylan's web chat";
          after = singleton "hippo.service";
          wants = singleton "hippo.service";
          environment = {
            # The seat's own installs, its claude among them.
            PATH = lib.mkForce (
              concatStringsSep ":" [
                "${seat.home}/.nix-profile/bin"
                "/etc/profiles/per-user/${seat.user}/bin"
                "/run/wrappers/bin"
                "/run/current-system/sw/bin"
              ]
            );
            OPENCODE_CONFIG = toString openCodeConfig;
          };
          serviceConfig = {
            SupplementaryGroups = [
              "usage"
              "opencode-auth"
            ];
            ExecStartPre = linkOmpModels;
            # The tool server reads this file and exits if it can't, leaving
            # each turn without it.
            LoadCredential = singleton "requests:${config.secrets.yeoman-requests-key.path}";
            WorkingDirectory = seat.home;
            NoNewPrivileges = false;
            ProtectSystem = false;
            PrivateTmp = false;
            # A restart ends the turn under way; the next message starts
            # afresh from the memory.
            Restart = "always";
            RestartSec = 10;
            # Each turn's claude and what it runs; paseo's bound.
            MemoryHigh = "12G";
            BindReadOnlyPaths = singleton "${seatClaudeEtc}:/etc/claude-code";
          };
        };

        # An up unit isn't a working Libri. This proves its site, its
        # memory and one model call through it; a failure here makes
        # switcharoo roll the deploy back.
        libri-ready = {
          description = "Proves Bridge's Libri answers";
          wantedBy = singleton "multi-user.target";
          after = [
            "libri.service"
            "hippo.service"
          ];
          restartTriggers = [
            config.systemd.units."libri.service".unit
            config.systemd.units."hippo.service".unit
          ];
          unitConfig.RequiresMountsFor = seat.hippo;
          environment.HIPPO_DIR = seat.hippo;
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.jq
            pkgs.socat
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = seat.user;
            TimeoutStartSec = 180;
          };
          script = ''
            site=http://127.0.0.1:${toString ports.libri}/api/host
            for _ in $(seq 40); do
              curl -fsS -m3 -o /dev/null "$site" && break
              sleep 1
            done
            curl -fsS -m3 -o /dev/null "$site"
            # The tool server: the daemon checks it itself, as its
            # credentials are in its own unit. Empty while that runs; a
            # build older than the check has no such field and passes.
            for _ in $(seq 45); do
              curl -fsS -m3 "$site" | jq -e 'has("tools") and .tools == null' >/dev/null || break
              sleep 1
            done
            curl -fsS -m3 "$site" | jq -e '(has("tools") | not) or .tools == true' >/dev/null
            # hippo is Type=simple: "started" comes seconds before its socket.
            for _ in $(seq 40); do
              timeout 5 ${seat.libriBuild}/bin/hippo status >/dev/null && break
              sleep 1
            done
            timeout 30 ${seat.libriBuild}/bin/hippo status >/dev/null
            for _ in $(seq 20); do
              [ -S ${seat.hippo}/compactor.sock ] && break
              sleep 1
            done
            printf '%s\n' '{"system":"Answer in one word.","memory":null,"prompt":"Say ready."}' |
              socat -t60 -T60 - UNIX-CONNECT:${seat.hippo}/compactor.sock |
              jq -e '.text | length > 0'
          '';
        };

        suki-hippo = {
          description = "Suki's memory";
          wantedBy = singleton "multi-user.target";
          path = singleton pkgs.claude-code;
          environment = {
            HIPPO_DIR = "${suki}/hippo";
            HIPPO_AGENT = "Suki";
            HIPPO_VIEW = "128000";
            HIPPO_BACKEND = "claude";
            HIPPO_MODEL = "haiku";
            HIPPO_EFFORT = "high";
          };
          serviceConfig = sukiSandbox // {
            StateDirectory = [
              "suki"
              "suki/hippo"
            ];
            StateDirectoryMode = "0700";
            LoadCredential = "claude-key:${config.secrets.suki-claude-key.path}";
            RuntimeDirectory = "suki-hippo";
            RuntimeDirectoryMode = "0700";
            ExecStartPre = claudeKey;
            ExecStart = "/var/lib/libri-build/suki/bin/hippo serve chat";
            Restart = "always";
            RestartSec = 5;
          };
        };

        suki = {
          description = "Suki, Gab's household assistant";
          wants = singleton "suki-hippo.service";
          after = singleton "suki-hippo.service";
          serviceConfig = sukiSandbox // {
            SupplementaryGroups = sukiSandbox.SupplementaryGroups ++ singleton computers.deskGroup;
            LoadCredential = [
              "claude-key:${config.secrets.suki-claude-key.path}"
              "home:${config.secrets.yeoman-home-token.path}"
              "fastmail:${config.secrets.suki-fastmail-mcp-token.path}"
              "requests:${config.secrets.yeoman-requests-key.path}"
            ];
            RuntimeDirectory = "suki";
            RuntimeDirectoryMode = "0700";
            ExecStartPre = [
              claudeKey
              sukiMcpTokens
            ];
            Restart = "always";
            RestartSec = 10;
            ReadWritePaths = [
              "${pages}/suki"
              house
              sukiDesk
            ];
            SocketBindAllow = "tcp:${toString ports.suki}";
            # Through the fence to its own runner.
            IPAddressAllow = fence.IPAddressAllow ++ singleton (computers.addr computers.indexes.suki);
          };
        };

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
      };
    };
}
