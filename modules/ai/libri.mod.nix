# Libri on Water (Libri's nix/module.nix): one assistant per person, each in
# the endless web chat of its own Libri, with its own memory. `libri` is the
# seat itself behind that chat, Bridge for Dylan on the seat's logins, tools
# and hippo. `suki` is Gab's: Libri as anyone installs it, sandboxed under her
# own user, its hippo its own child, with a computer for code
# (assistant-computer.mod.nix). Both run the one build at seat.libriBuild,
# which deploy_libri.sh moves and restarts both on, so a Libri change needs
# no switch here.
#
# All of Libri's settings sit in its config file: an unknown key stops the
# build from starting. Each offers the harnesses on its own PATH; Suki's
# holds only Claude Code.
#
# Model calls reach only what the instance's MCP file names. Suki has pictures
# (assistant-image.py), drawn by the image service, the only assistant-side
# holder of a Codex login, and Home Assistant's own MCP server. Fastmail is a
# sign-in in Libri's Settings > Connections, as on the seat.
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
        tools.usage = "/run/usage.sock";
      };
      site = unit: subdomain: {
        # Each person's instance is its own host on its own port, reachable
        # at Water's tailnet address for the app served at app.libri.is, as
        # Paseo's daemon is (0.0.0.0:6768): the firewall trusts only
        # tailscale0, so the LAN and the bridges still cannot reach it.
        # Chromium calls it from the https copy (after its local-network
        # prompt), Safari from the http one.
        listen = "0.0.0.0:${toString ports.${unit}}";
        url = host subdomain;
        pages = "${pages}/${unit}";
        pages_url = host subdomain;
        # The apps talk to it with no sign-in on the tailnet.
        open = "1";
        origins = "https://app.libri.is,http://app.libri.is";
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
      } (readFile ./assistant-image.py);

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

      # What Libri adds to its own tools on the seat's turns. Not web:
      # Libri's own web_search and web_fetch reach Parallel for every
      # harness, with its retries.
      seatMcp = (pkgs.formats.json { }).generate "seat-libri-mcp.json" {
        mcpServers = removeAttrs config.seat.mcpServers [ "web" ];
      };
      # What is true of this ship, for any harness.
      seatGuide = pkgs.writeText "seat-libri-guide.md" lib.ship.guide;
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
      # The host's own llama-swap, at the seat-plane address its fence admits,
      # on hosts that serve one.
      ompLocal = lib.trivial.mapNullable (inference: {
        baseURL = "http://${topology.seatInferenceAddr}:${toString inference.port}/v1";
        models = inference.ompModels;
      }) (config.inference or null);
      ompModels = pkgs.writeText "libri-omp-models.yml" (
        lib.ship.opencode.ompModels (keys // { local = ompLocal; })
      );
      # omp reads its providers only from its home.
      linkOmpModels = pkgs.writeShellScript "libri-omp-models" ''
        ${pkgs.coreutils}/bin/mkdir -p ${seat.home}/.omp/agent
        ${pkgs.coreutils}/bin/ln -sfn ${ompModels} ${seat.home}/.omp/agent/models.yml
      '';

      suki = "/var/lib/suki";
      sukiDesk = "${computers.desks}/suki";
      # The servers Gab added beside Libri's own, which the daemon hands
      # every turn itself.
      sukiMcp = (pkgs.formats.json { }).generate "suki-mcp.json" {
        mcpServers = {
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
        };
      };
      # Claude Code bills to the key in its environment. systemd reads the
      # unit's EnvironmentFile between ExecStartPre and ExecStart, so the key
      # rides a credential and never sits in a file past the unit's life.
      claudeKey = pkgs.writeShellScript "claude-key" ''
        umask 077
        printf 'ANTHROPIC_API_KEY=%s\n' "$(< "$CREDENTIALS_DIRECTORY/claude-key")" > "$RUNTIME_DIRECTORY/claude.env"
      '';
      # The seat's claude on the setup token, the same way, not the browser
      # login in ~/.claude: that one rotates, and a refused renewal blanked it
      # on 10-30. The unit's other harnesses inherit it, but they run as the
      # seat, which could read that login anyway.
      claudeToken = pkgs.writeShellScript "claude-token" ''
        umask 077
        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$(< "$CREDENTIALS_DIRECTORY/claude-token")" > "$RUNTIME_DIRECTORY/claude.env"
      '';
      # The tokens rise from their credentials into a private copy of the file.
      sukiMcpTokens = pkgs.writeShellScript "suki-mcp-tokens" ''
        umask 077
        ${pkgs.gnused}/bin/sed \
          -e "s|@HOME_TOKEN@|$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/home")|" \
          ${sukiMcp} > "$RUNTIME_DIRECTORY/mcp.json"
      '';

      # The homeserver and resolver on loopback, and the internet for the
      # model; not the tailnet, the LAN or the seat's loopback address.
      fence = {
        IPAddressAllow = fences.loopback;
        IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
      };
      sukiSandbox = lib.ship.hardened.tenant // {
        User = "suki";
        Group = "suki";
        SupplementaryGroups = [
          "yeoman-image"
          "yeoman-household"
          "usage"
          computers.deskGroup
        ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        EnvironmentFile = "-%t/%N/claude.env";
      };
    in
    {
      imports = singleton inputs.libri.nixosModules.default;

      services.libri.instances.libri = {
        package = seat.libriBuild;
        inherit (seat) user;
        # One browser for agents: logged out until Dylan allows a site's logins.
        agentBrowser.enable = true;
        settings = lib.recursiveUpdate (shared "libri") {
          name = "Bridge";
          person = "Dylan";
          daemon = site "libri" "si";
          hippo = {
            dir = seat.hippo;
            # The seat's hippo (seat/hippo.mod.nix serves it); the title its
            # history already goes under.
            shared = "Bridge";
          };
          harness = {
            mcp = toString seatMcp;
            identity = toString (identity "Bridge" "the ship's engineer");
            instructions = toString seatGuide;
            # Full ids, so the picker can show each model's version.
            models = "claude-opus-5-5,claude-sonnet-5-5,claude-haiku-5-5,claude-fable-5-1";
            efforts = "low,medium,high,xhigh,max";
            # llm-agents installs OpenCode 2 under this name (agent-clis.mod.nix).
            opencode.command = "opencode2";
          };
        };
      };

      services.libri.instances.suki = {
        package = seat.libriBuild;
        harnesses = singleton pkgs.claude-code;
        settings = lib.recursiveUpdate (shared "suki") {
          name = "Suki";
          person = "Gab";
          style = "Gab likes a slightly warmer tone.";
          daemon = site "suki" "suki";
          hippo = {
            backend = "claude";
            model = "haiku";
            effort = "high";
          };
          # Notes to and from the other assistants and the seat.
          household = {
            dir = house;
            inherit members;
          };
          harness = {
            mcp = "/run/suki/mcp.json";
            identity = toString (identity "Suki" "Gab's household assistant");
            # An assistant: Libri's tools only, no shell or files.
            coding = "0";
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
              ["hippo.service", "libri.service", "libri-hippo.service", "suki.service"].indexOf(action.lookup("unit")) >= 0 &&
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
            LoadCredential = "claude-token:${config.secrets.agent-claude-token.path}";
            RuntimeDirectory = "libri";
            RuntimeDirectoryMode = "0700";
            ExecStartPre = [
              linkOmpModels
              claudeToken
            ];
            EnvironmentFile = "-%t/%N/claude.env";
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

        suki = {
          description = "Suki, Gab's household assistant";
          serviceConfig = sukiSandbox // {
            SupplementaryGroups = sukiSandbox.SupplementaryGroups ++ singleton computers.deskGroup;
            LoadCredential = [
              "claude-key:${config.secrets.suki-claude-key.path}"
              "home:${config.secrets.yeoman-home-token.path}"
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
