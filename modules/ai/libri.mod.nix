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
# (assistant-image.py), drawn by codex-image, the only assistant-side holder
# of a Codex login, and Home Assistant's own MCP server. Fastmail is a
# sign-in in Libri's Settings > Connections, as on the seat.
#
# The two reach each other over A2A (Libri's a2a.rs), sharing one token in
# a directory their common group can read; a message lands in the other's
# chat as a note, and a watch's share_with sends its answer the same way.
# The household's shared lists wait in that directory's book.db for the
# household MCP server (household-mcp.py), which Libri no longer serves.
# Memories stay apart.
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
      pages = "/var/lib/libri-pages";
      host = sub: "https://${sub}.${config.shipProxy.domain}";

      ports = {
        libri = 8951;
        suki = 8952;
      };
      # The other assistant, by its name and its person's, as share_with
      # names them (a2a.rs `peers`).
      peer =
        unit: names:
        concatStringsSep "," (map (n: "${n}=http://127.0.0.1:${toString ports.${unit}}") names);
      # What both configs say alike; `to` is the other instance.
      shared = to: names: {
        a2a = {
          token_file = "${house}/a2a.token";
          peers = peer to names;
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

      image = pkgs.writers.writePython3Bin "codex-image-mcp" {
        libraries = singleton pkgs.python3Packages.mcp;
        flakeIgnore = singleton "E501";
      } (readFile ./assistant-image.py);

      # One connection, one picture: the description on stdin, the PNG out.
      # Codex keeps each thread's pictures under its thread id.
      draw = pkgs.writeShellApplication {
        name = "codex-image";
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
            | "codex-image: tokens model=\($m) input=\(.input_tokens - .cached_input_tokens) cache_read=\(.cached_input_tokens) cache_write=0 output=\(.output_tokens)"' <<< "$out" >&2
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
      ompModels = pkgs.writeText "libri-omp-models.yml" (lib.ship.opencode.ompModels keys);
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
      sukiSandbox =
        lib.ship.hardened.tenant
        // {
          User = "suki";
          Group = "suki";
          SupplementaryGroups = [
            "codex-image"
            "libri-household"
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
        settings = lib.recursiveUpdate (shared "suki" [ "Suki" "Gab" ]) {
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
            # llm-agents installs OpenCode 2 under this name (agent-clis.mod.nix).
            opencode.command = "opencode2";
          };
        };
      };

      services.libri.instances.suki = {
        package = seat.libriBuild;
        harnesses = singleton pkgs.claude-code;
        settings = lib.recursiveUpdate (shared "libri" [ "Bridge" "Dylan" ]) {
          name = "Suki";
          person = "Gab";
          style = "Gab likes a slightly warmer tone.";
          daemon = site "suki" "suki";
          hippo = {
            backend = "claude";
            model = "haiku";
            effort = "high";
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

      # codex-image holds the household's one Codex login, on the ChatGPT
      # subscription; the assistants reach only its socket. Log in once,
      # with the codex from the unit's script (not on PATH), after
      # `sudo install -d -o codex-image -g codex-image -m 700 /var/lib/codex-image`:
      # sudo -u codex-image env HOME=/var/lib/codex-image CODEX_HOME=/var/lib/codex-image <codex> login --device-auth
      users.users.codex-image = {
        isSystemUser = true;
        group = "codex-image";
        home = "/var/lib/codex-image";
      };
      # Bridge's Libri runs as the seat, and reads the A2A token as Suki does.
      users.users.${seat.user}.extraGroups = singleton "libri-household";
      users.groups.codex-image = { };
      users.groups.libri-household = { };

      # The state these had under their yeoman names, moved once before any
      # unit starts on the new names. Drop once Water has switched past it.
      system.activationScripts.libri-yeoman-names = {
        deps = [
          "users"
          "groups"
        ];
        text = ''
          move() { if [ -e "$1" ] && [ ! -e "$2" ]; then mv "$1" "$2"; fi; }
          move /var/lib/yeoman-household ${house}
          move /var/lib/yeoman-pages ${pages}
          move /var/lib/yeoman-image /var/lib/codex-image
          # Messages left in the household's mailboxes go to each Libri's own
          # inbox, where A2A messages now wait; the mailboxes and the seat's
          # boxes are kept aside, not deleted.
          deliver() {
            [ -d "$1" ] || return 0
            install -d -o "$3" -g "$3" -m 700 "$2"
            for f in "$1"/*; do
              [ -f "$f" ] || continue
              mv "$f" "$2/$(basename "$f")"
              chown "$3:$3" "$2/$(basename "$f")"
            done
          }
          deliver ${house}/mail/libri /var/lib/libri/inbox ${seat.user}
          deliver ${house}/mail/suki /var/lib/suki/inbox suki
          if [ -d ${house}/mail ] || [ -d ${house}/seat ]; then
            install -d -m 2770 -g libri-household ${house}/retired
            move ${house}/mail ${house}/retired/mail
            move ${house}/seat ${house}/retired/seat
          fi
          if [ -d ${house} ]; then chgrp -R libri-household ${house}; fi
          if [ -d /var/lib/codex-image ]; then chown -R codex-image:codex-image /var/lib/codex-image; fi
        '';
      };

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

      systemd.tmpfiles.settings.libri-pages = {
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
      systemd.tmpfiles.settings.libri-build."/var/lib/libri-build".d = {
        user = seat.user;
        group = seat.user;
        mode = "0755";
      };
      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              ["hippo.service", "libri.service", "suki.service"].indexOf(action.lookup("unit")) >= 0 &&
              ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0 &&
              subject.user == "${seat.user}") {
            return polkit.Result.YES;
          }
        });
      '';

      # Setgid, so what one assistant writes stays the group's.
      systemd.tmpfiles.settings.libri-household =
        lib.attrsets.genAttrs
          [ house ]
          (_: {
            d = {
              user = "root";
              group = "libri-household";
              mode = "2770";
            };
          });

      systemd.sockets.codex-image = {
        description = "Pictures for the household assistants";
        wantedBy = singleton "sockets.target";
        socketConfig = {
          ListenStream = "/run/codex-image.sock";
          Accept = true;
          MaxConnections = 2;
          SocketMode = "0660";
          SocketGroup = "codex-image";
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

        "codex-image@" = {
          description = "One picture for a household assistant";
          environment = {
            HOME = "/var/lib/codex-image";
            CODEX_HOME = "/var/lib/codex-image";
          };
          serviceConfig =
            lib.ship.hardened.tenant
            // fence
            // {
              User = "codex-image";
              Group = "codex-image";
              StateDirectory = "codex-image";
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
