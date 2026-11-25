# Libri on Water (Libri's nix/module.nix): one assistant per person, each in
# the endless web chat of its own Libri, with its own memory. `libri` is the
# seat itself behind that chat, Bridge for Dylan on the seat's logins, tools
# and hippo. `suki` is Gab's: Libri as anyone installs it, sandboxed under her
# own user, its hippo its own child, with a computer for code
# (assistant-computer.mod.nix). Both assistants and the seat's core daemon
# run the build at seat.libriBuild, which deploy_libri.sh moves and restarts
# them on, so a Libri change needs no switch here.
#
# Libri keeps every word of its prompts itself: each instance's rules,
# opening with who it is, in AGENTS.md and the host's facts in HOST.md, in
# its state, edited in Settings. This module installs and configures it, and
# writes none.
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
# The two assistants reach each other over A2A as peers, paired in Libri's
# Settings > Hosts > Peers with a credential of their own (Libri's peers.rs),
# which each keeps in its state. A message lands in the other's chat as a
# note. Memories stay apart: nothing else passes between them.
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
      inherit (lib.attrsets)
        attrNames
        attrValues
        filterAttrs
        genAttrs
        listToAttrs
        mapAttrs
        mapAttrsToList
        nameValuePair
        optionalAttrs
        recursiveUpdate
        ;
      inherit (lib.lists)
        concatMap
        filter
        last
        optionals
        singleton
        ;
      inherit (lib.meta) getExe getExe';
      inherit (lib.modules) mkForce mkIf;
      inherit (lib.strings)
        hasSuffix
        optionalString
        readFile
        concatMapStringsSep
        concatStringsSep
        escapeShellArg
        escapeShellArgs
        splitString
        ;
      inherit (lib.ship) fences computers topology;

      seat = topology.seat;
      core = "${seat.libriBuild}/bin/libri-core";
      addonsBuild = seat.libriAddonsBuild;
      addonBinary = name: "${addonsBuild}/${name}/bin/libri-${name}";
      coreRuntime = "/run/libri-core";
      coreState = "/var/lib/libri-core";
      # Today's Libri's state (its unit's StateDirectory), where its wiki
      # and its connections' logins live.
      libriState = "/var/lib/libri";
      coreSocket = "${coreRuntime}/owner.sock";
      coreClients = "${coreRuntime}/client.sock";
      seatPath = concatStringsSep ":" [
        "/etc/profiles/per-user/${seat.user}/bin"
        "/run/wrappers/bin"
        "/run/current-system/sw/bin"
      ];
      # Server-sent events stream as they come; uploads may be as big as the
      # chat takes (UPLOAD_MAX in site.rs).
      proxyExtra = "proxy_buffering off; client_max_body_size 100m;";
      # The assistants' sites: a directory each, read by nginx as its group.
      pages = "/var/lib/yeoman-pages";
      host = sub: "https://${sub}.${config.shipProxy.domain}";

      ports = {
        libri = 8951;
        suki = 8952;
      };

      # STAGE 2: THE CORE'S OWN CLIENTS
      # The core, the gateway, its web view and the enabled add-ons all run
      # from deployed links that deploy_libri.sh moves on release; speech's
      # local models stay on the pinned libri input as a read-only store path.
      libriPackages = inputs.libri.packages.${pkgs.stdenv.hostPlatform.system} or { };
      addonNames = [
        "files"
        "lists"
        "boards"
        "pages"
        "search"
        "image"
        "mail"
        "a2a"
        "speech"
        "layout"
        "ui"
      ];
      addons = config.libri.core.addons |> filterAttrs (_: addon: addon.enable);
      # speech runs on the host's own models unless told to use a cloud
      # service; the models are a read-only store path from the same build.
      speechLocal = config.libri.core.addons.speech.provider == "local";
      # Each add-on's variables: the host's, and for speech the provider
      # and, run locally, its models.
      addonEnvironment =
        name:
        config.libri.core.addons.${name}.environment
        // optionalAttrs (name == "speech") (
          {
            LIBRI_SPEECH_PROVIDER = config.libri.core.addons.speech.provider;
          }
          // optionalAttrs (speechLocal && libriPackages ? speech-models) {
            LIBRI_SPEECH_MODELS_DIR = "${libriPackages.speech-models}";
          }
        );
      coreSetup = (pkgs.formats.toml { }).generate "libri-core.toml" {
        # client.sock admits the libri-clients group, so a client running
        # as its own user (the gateway) reaches the core; owner.sock stays
        # the seat's alone.
        clients = {
          mode = "0660";
          group = coreClientsGroup;
        };
        # Mode a child session gets when its parent runs on a different harness:
        # each built-in harness's autonomous widening mode.
        harness = {
          claude.child_mode = "bypassPermissions";
          codex.child_mode = "never";
          agy.child_mode = "full-access";
          muse.child_mode = "allowAll";
          omp.child_mode = "full-access";
          opencode.child_mode = "full-access";
          pi.child_mode = "full-access";
        };
        mcp =
          coreServers
          // (
            addons
            |> mapAttrs (
              name: _:
              {
                command = singleton (addonBinary name);
              }
              // optionalAttrs (addonEnvironment name != { }) { env = addonEnvironment name; }
            )
          );
      };
      # The servers every turn of today's Libri holds beside its own tools
      # (servers.rs, list_asking), for every session the core starts itself:
      # triggers, the web view's chats and `libri session start`. Each keeps
      # today's name, so the setup of a turn today's Libri forwards, which
      # names its own, replaces the entry rather than doubling it.
      coreServers =
        (
          seatServers
          |> mapAttrs (
            name: server:
            if server ? url then
              { inherit (server) url; } // optionalAttrs (server ? headers) { inherit (server) headers; }
            else
              {
                command = singleton server.command ++ server.args or [ ];
              }
              // optionalAttrs (server ? env) { inherit (server) env; }
          )
        )
        // {
          # The memory, as today's Libri hands it (memory.command), on the
          # seat's hippo2 and the record hippo keeps.
          hippo2 = {
            command = [
              (getExe config.services.hippo2.finalPackage)
              "mcp"
            ];
            env.HIPPO_DIR = seat.hippo;
          };
          # Dylan's wiki, writable as on his own turns today: the deployment
          # layer is one set for every session, so the core's workers write
          # too, where today's Libri gives a worker's turn --read-only.
          wiki.command = [
            "${seat.libriBuild}/bin/wiki"
            "serve"
            "${libriState}/wiki"
          ];
          # Today's Libri's relay to Fastmail (connections.rs) on the login it
          # renews in ${libriState}/connections. A tool set to ask first asks
          # the person through the core, as a request on the session that
          # called it; the core fills in that session's socket, token and id.
          fastmail = {
            command = [
              "${seat.libriBuild}/bin/libri"
              "connection"
              libriState
              "fastmail"
            ];
            env = {
              STATE_DIRECTORY = libriState;
              LIBRI_ASK = "core";
              LIBRI_SOCKET.session = "socket";
              LIBRI_TOKEN.session = "token";
              LIBRI_SESSION.session = "id";
            };
          };
        };

      legacy = config.libri.legacy;
      a2aCfg = config.libri.core.addons.a2a;
      a2aServe = addons ? a2a && a2aCfg.listen != null;
      a2aPort = last (splitString ":" a2aCfg.listen);
      a2aPeersFile = a2aCfg.environment.LIBRI_A2A_PEERS_FILE or "${coreState}/a2a-peers.json";
      a2aName = a2aCfg.environment.LIBRI_A2A_NAME or null;

      gateway = config.libri.gateway;
      gatewayState = "/var/lib/libri-gateway";
      gatewayToken = "${gatewayState}/admin.token";
      # nginx alone reaches this socket, and the gateway trusts X-Real-IP
      # only from a peer the kernel names as nginx's user; TCP never does.
      gatewayProxySocket = "/run/libri-gateway/proxy.sock";
      # The gateway's UID, fixed at the one NixOS first allotted Water
      # (/var/lib/nixos/uid-map), which owns /var/lib/libri-gateway; the
      # add-ons admit only this peer on their sockets.
      gatewayUid = 953;
      gatewayGid = 940;

      # The add-ons the gateway serves to its clients over HTTP, each on its
      # own Unix socket beside the stdio server the core's sessions get. ui
      # holds nothing a client reads, so it stays stdio alone.
      servedAddons =
        [
          "boards"
          "pages"
          "lists"
          "files"
          "speech"
          "layout"
        ]
        |> filter (name: addons ? ${name});
      addonSocket = name: "/run/libri-addons/${name}/${name}.sock";
      # Each add-on's stores are the host's variables naming a directory or
      # a state path, not the models the module adds; a variable naming a
      # token file is a credential the seat writes, which the unit waits for.
      addonStores =
        name:
        config.libri.core.addons.${name}.environment
        |> filterAttrs (variable: _: hasSuffix "_DIR" variable || hasSuffix "_STATE" variable)
        |> attrValues;
      addonCredentials =
        name:
        config.libri.core.addons.${name}.environment
        |> filterAttrs (variable: _: hasSuffix "_TOKEN_FILE" variable)
        |> attrValues;
      # speech alone calls out, to its HTTPS speech service, and only when
      # it does not run on the host's own models.
      addonCallsOut = name: name == "speech" && !speechLocal;
      # Today's Libri's own tools that each add-on takes over (Libri's
      # tools.rs). A turn today's Libri forwards to the core would otherwise
      # hold both, each on its own store, so today's Libri withholds its own
      # for every add-on the core runs. send_file, draft_mail and the rest
      # have no add-on yet and stay.
      supersededTools = {
        files = [
          "files"
          "read_file"
        ];
        lists = [
          "lists"
          "list_add"
          "list_remove"
        ];
        boards = [
          "boards_list"
          "board_read"
          "board_note"
          "board_edit"
        ];
        pages = [
          "pages"
          "page_data"
          "page_data_change"
        ];
        # The tiles today's Libri moves are those of its own site, which the
        # gateway's web view replaces.
        layout = [
          "layout"
          "layout_change"
          "tile_open"
          "layout_undo"
        ];
        ui = [
          "offer_replies"
          "show_card"
          "show_page"
        ];
        search = [
          "web_search"
          "web_fetch"
        ]
        # x_search answers from the add-on only on the host's xAI login.
        ++ optionals (config.libri.core.addons.search.environment ? LIBRI_XAI_CONNECTION) [ "x_search" ];
        image = singleton "make_image";
        mail = singleton "draft_mail";
        a2a = singleton "message_peer";
      };
      withheldTools = addons |> attrNames |> concatMap (name: supersededTools.${name} or [ ]);
      addonUnits =
        servedAddons
        |> map (
          name:
          nameValuePair "libri-addon-${name}" {
            description = "Libri's ${name} add-on, served to the gateway over HTTP";
            wantedBy = singleton "multi-user.target";
            before = singleton "libri-gateway.service";
            unitConfig = {
              ConditionFileIsExecutable = addonBinary name;
            }
            // optionalAttrs (addonCredentials name != [ ]) {
              ConditionPathExists = addonCredentials name;
            };
            environment = addonEnvironment name;
            serviceConfig = lib.ship.hardened.tenant // {
              User = seat.user;
              # The gateway's group reaches the 0660 socket; no one else does.
              Group = "libri-gateway";
              # SO_PEERCRED must carry the gateway's real UID for --peer-uid.
              PrivateUsers = false;
              RuntimeDirectory = "libri-addons/${name}";
              RuntimeDirectoryMode = "0750";
              ReadWritePaths = addonStores name;
              ExecStart = escapeShellArgs [
                (addonBinary name)
                "serve"
                "--http-socket"
                (addonSocket name)
                "--peer-uid"
                (toString gatewayUid)
              ];
              RestrictAddressFamilies = [
                "AF_UNIX"
              ]
              ++ optionals (addonCallsOut name) [
                "AF_INET"
                "AF_INET6"
              ];
              IPAddressDeny = if addonCallsOut name then fences.internetOnlyDeny else "any";
              # ONNX Runtime reads /proc/cpuinfo to size its threads to the
              # host's cores; the tenant default hides it.
              ProcSubset = if name == "speech" && speechLocal then "all" else lib.ship.hardened.tenant.ProcSubset;
              Restart = "always";
              RestartSec = 10;
            };
          }
        )
        |> listToAttrs;
      coreClientsGroup = "libri-clients";
      # Shared by the service and `libri-gateway pair`, `connector` and
      # `revoke`, which must reach the same store and credential.
      gatewayEnvironment = {
        LIBRI_SOCKET = coreClients;
        LIBRI_GATEWAY_STATE = "${gatewayState}/gateway.sqlite";
        LIBRI_GATEWAY_TOKEN_FILE = gatewayToken;
        LIBRI_GATEWAY_URL = host gateway.subdomain;
      };
      # The web view ships in the deployed build beside the gateway (Libri
      # 0.9.119 and later), so the two always move in one release.
      gatewayWeb = "${seat.libriBuild}/web";
      gatewayServe = escapeShellArgs (
        [
          "${seat.libriBuild}/bin/libri-gateway"
          "serve"
          "--listen"
          gateway.listen
          "--web-dir"
          gatewayWeb
          "--proxy-socket"
          gatewayProxySocket
          "--proxy-uid"
          (toString config.ids.uids.nginx)
          # Layer 2 beside the tailnet: paired devices reach the gateway over
          # Iroh QUIC through n0's public relays.
          "--iroh"
        ]
        ++ (
          servedAddons
          |> concatMap (name: [
            "--addon"
            "${name}=${addonSocket name}"
          ])
        )
        ++ optionals (gateway.tailnetOwner != null) [
          "--tailnet-whois"
          "--tailnet-owner"
          gateway.tailnetOwner
        ]
      );

      # A program on the seat's PATH with its service's settings as defaults,
      # in any shell, login or not, so a command reaches the store and the
      # daemon the service does.
      seatCommand =
        name: environment: program:
        pkgs.writeShellScriptBin name (
          (
            environment
            |> mapAttrsToList (variable: value: "export ${variable}=\${${variable}:-${escapeShellArg value}}")
          )
          ++ singleton "exec ${program} \"$@\""
          |> concatStringsSep "\n"
        );
      # `libri` is the core's CLI, attached to libri-core.service: without
      # these, it looks under $XDG_RUNTIME_DIR and starts a second daemon.
      coreEnvironment = {
        LIBRI_RUNTIME_DIR = coreRuntime;
        LIBRI_DATA_DIR = coreState;
      };
      # The gateway's store and admin credential are its user's alone, out
      # of the seat's (and so the agents') reach: the command takes that
      # user through sudo, so it runs for a person with sudo, not the seat.
      gatewayCommand = pkgs.writeShellScriptBin "libri-gateway" (
        (
          [
            ''if [ "$(${pkgs.coreutils}/bin/id -un)" != libri-gateway ]; then''
            ''exec /run/wrappers/bin/sudo -u libri-gateway -- "$0" "$@"''
            "fi"
          ]
          ++ (
            gatewayEnvironment
            |> mapAttrsToList (variable: value: "export ${variable}=\${${variable}:-${escapeShellArg value}}")
          )
          ++ singleton "exec ${seat.libriBuild}/bin/libri-gateway \"$@\""
        )
        |> concatStringsSep "\n"
      );
      coreCommands = [
        (seatCommand "libri" coreEnvironment core)
      ]
      ++ (
        addons
        |> mapAttrsToList (name: _: seatCommand "libri-${name}" (addonEnvironment name) (addonBinary name))
      );
      # What both configs say alike.
      shared = {
        harness = {
          default = "claude";
          model = "opus";
        };
        tools.usage = "/run/usage.sock";
        # What the System tile and the `system` tool watch on Water: the
        # units the house leans on, and the disks that fill.
        system = {
          services = [
            "frigate"
            "hob"
            "immich-server"
            "nix-daemon"
          ]
          ++ (
            if legacy.enable then
              singleton "libri"
            else
              singleton "libri-core" ++ optionals gateway.enable (singleton "libri-gateway")
          )
          ++ singleton "hippo2";
          mounts = [
            "/"
            "/nix"
            "/srv/storage"
          ];
        };
      };
      site = unit: subdomain: login: {
        # Each person's instance is its own host on its own port, reachable
        # at Water's tailnet address for the app served at app.libri.is, as
        # Paseo's daemon is (0.0.0.0:6768): the firewall trusts only
        # tailscale0, so the LAN and the bridges still cannot reach it.
        # Chromium calls it from the https copy (after its local-network
        # prompt), Safari from the http one.
        listen = "0.0.0.0:${toString ports.${unit}}";
        url = host subdomain;
        pages = "${pages}/${unit}";
        # Page links open in the Library of the app at app.libri.is, on
        # whichever host the reader has open.
        pages_url = "https://app.libri.is";
        # The tailnet is the sign-in: tailscaled names each caller, only this
        # person's login gets in, signed in with no pairing; loopback (the
        # machine itself) stays in.
        tailnet = login;
        origins = "https://app.libri.is,http://app.libri.is";
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
      # harness, with its retries. Not hippo2: Libri hands every turn its
      # memory itself (memory.command), naming the memory a turn is in.
      seatMcp = (pkgs.formats.json { }).generate "seat-libri-mcp.json" {
        mcpServers = seatServers;
      };
      seatServers =
        removeAttrs config.seat.mcpServers [
          "web"
          "hippo2"
        ]
        # The house (hob.mod.nix): its cameras, weather, air and calendar,
        # and the cards Libri draws for them.
        // optionalAttrs (config.services ? hob && config.services.hob.enable) {
          hob = {
            type = "http";
            url = "http://127.0.0.1:${toString config.services.hob.port}/mcp";
          };
        }
        // moneyMcp;
      # The household's money (money.mod.nix): its reads and the page's four
      # changes, for both assistants.
      moneyMcp = optionalAttrs (config.systemd.services ? money) {
        money = {
          type = "http";
          url = "http://127.0.0.1:${toString config.money.mcpPort}/mcp";
        };
      };
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
        }
        // moneyMcp;
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
      startCore = pkgs.writeShellScript "start-libri-core" ''
        CLAUDE_CODE_OAUTH_TOKEN=$(< "$CREDENTIALS_DIRECTORY/claude-token") || exit 1
        export CLAUDE_CODE_OAUTH_TOKEN
        exec ${core} --runtime-dir "$RUNTIME_DIRECTORY" --data-dir "$STATE_DIRECTORY" daemon --no-holder-scope
      '';
      # The tokens rise from their credentials into a private copy of the file.
      sukiMcpTokens = pkgs.writeShellScript "suki-mcp-tokens" ''
        umask 077
        ${getExe pkgs.gnused} \
          -e "s|@HOME_TOKEN@|$(${getExe' pkgs.coreutils "tr"} -d '\r\n' < "$CREDENTIALS_DIRECTORY/home")|" \
          ${sukiMcp} > "$RUNTIME_DIRECTORY/mcp.json"
      '';

      # The resolver on loopback and the internet for the model; not the
      # tailnet, the LAN or the seat's loopback address.
      fence = {
        IPAddressAllow = fences.loopback;
        IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
      };
      sukiSandbox = lib.ship.hardened.tenant // {
        User = "suki";
        Group = "suki";
        SupplementaryGroups = [
          "yeoman-image"
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
      inherit (lib.options) mkOption;
      inherit (lib) types;
      limits = config.libri.limits;
    in
    {
      imports = singleton inputs.libri.nixosModules.default;

      # The cgroup limits Libri sets below itself (Libri's cgroup.rs), as
      # `file=value` pairs, on a host that delegates the unit its cgroup.
      # Null leaves Libri's own: no move for server and harness, and the
      # browser's built-in cap.
      options.libri.limits = {
        server = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Limits for the daemon's own `server` leaf (LIBRI_SERVER_CGROUP).";
        };
        harness = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Limits for the `harness` cgroup every harness and what it runs share (LIBRI_HARNESS_CGROUP).";
        };
        browser = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Limits for the agents' `browser` cgroup (LIBRI_BROWSER_CGROUP).";
        };
      };

      # The Stage 2 add-ons (Libri's addons/NAME), each its flake package
      # serving MCP on stdio, given to every session of the seat's core from
      # its deployment layer, /etc/libri-core/libri.toml.
      options.libri.core.addons =
        genAttrs addonNames (name: {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Give the core's sessions the ${name} add-on.";
          };
          environment = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = "Variables for libri-${name}, also the defaults of the seat's `libri-${name}` command.";
          };
        })
        |> recursiveUpdate {
          speech.provider = mkOption {
            type = types.enum [
              "local"
              "openai"
            ];
            default = "local";
            description = ''
              Where speech runs: `local` on the host's own models (Nemotron
              speech to text, Kokoro text to speech), with no network and no
              key; `openai` on an OpenAI-compatible service, whose key file
              LIBRI_SPEECH_TOKEN_FILE names.
            '';
          };
          a2a = {
            listen = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Loopback address and port for the inbound A2A HTTP receiver (`libri-a2a serve`); null keeps a2a outbound-only.";
            };
            person = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Person name advertised in the inbound A2A Agent Card.";
            };
            coreTokenFile = mkOption {
              type = types.str;
              default = "${coreState}/a2a.token";
              description = "File holding the non-approve core credential (`read,operate`, `reach: all`) for inbound A2A delivery.";
            };
          };
        };

      options.libri.legacy.enable = mkOption {
        type = types.bool;
        default = true;
        description = "Run Dylan's legacy libri.service web chat beside Stage 2 libri-core and libri-gateway.";
      };

      options.libri.site.subdomain = mkOption {
        type = types.str;
        default = "si";
        description = "Name under the proxy's domain today's Libri, the seat's web chat, is served at.";
      };

      # The core's network clients: paired devices, the Android app and the
      # web view, on `/v1` beside today's site.
      options.libri.gateway = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Run libri-gateway against the seat's core.";
        };
        port = mkOption {
          type = types.port;
          default = 8953;
          description = "Port the gateway serves plain HTTP on, behind the proxy's TLS.";
        };
        listen = mkOption {
          type = types.str;
          default = "127.0.0.1:${toString gateway.port}";
          description = "Address the gateway binds for direct clients; the proxy uses its Unix socket.";
        };
        subdomain = mkOption {
          type = types.str;
          default = "core";
          description = "Name under the proxy's domain the gateway is served at.";
        };
        aliases = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Further names under the proxy's domain that also serve the
            gateway, so a browser or device paired at an earlier name keeps
            its credential, which its origin holds.
          '';
        };
        tailnetOwner = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Tailscale login whose devices the gateway admits by tailscaled's
            whois, without pairing. A direct tailnet connection names its
            caller. The proxy reaches the gateway on its own Unix socket, where
            libri-gateway 0.9.121 and later reads the caller from X-Real-IP
            only when the kernel names the peer as nginx's user; on TCP,
            loopback included, it never trusts the header.
          '';
        };
      };

      config = {

        services.libri.instances =
          optionalAttrs legacy.enable {
            libri = {
              package = seat.libriBuild;
              inherit (seat) user;
              # One browser for agents: logged out until Dylan allows a site's logins.
              agentBrowser.enable = true;
              settings = recursiveUpdate shared {
                name = "Bridge";
                person = "Dylan";
                # One address for the household: Dylan's Libri answers on the
                # tailnet port and passes Gab's devices on to hers, by tailscaled's
                # word on who is calling.
                daemon = site "libri" config.libri.site.subdomain "ddcleary1@gmail.com" // {
                  forward = "gabcaminiti10@gmail.com=http://127.0.0.1:${toString ports.suki}";
                };
                hippo = {
                  dir = seat.hippo;
                  # The seat's hippo (seat/hippo.mod.nix serves it); the title its
                  # history already goes under.
                  shared = "Bridge";
                };
                # The memory every turn recalls from: the seat's hippo2
                # (seat/hippo2.mod.nix), the program that finds its memories.
                memory.command = "${lib.meta.getExe config.services.hippo2.finalPackage} mcp";
                harness = {
                  mcp = toString seatMcp;
                  efforts = "low,medium,high,xhigh,max";
                  # llm-agents installs OpenCode 2 under this name (agent-clis.mod.nix).
                  opencode.command = "opencode2";
                };
                # Merged with shared's tools.usage.
                tools = optionalAttrs (withheldTools != [ ]) {
                  withheld = concatStringsSep "," withheldTools;
                };
              };
            };
          }
          // {
            suki = {
              package = seat.libriBuild;
              harnesses = singleton pkgs.claude-code;
              settings = recursiveUpdate shared {
                name = "Suki";
                person = "Gab";
                style = "Gab likes a slightly warmer tone.";
                # Gab's devices reach Suki through Dylan's Libri; the shared Mac,
                # on the tailnet as Dylan's device metal, reaches it on its own
                # port, where only Gab and that one device get in.
                daemon = site "suki" "suki" "gabcaminiti10@gmail.com,ddcleary1@gmail.com/metal";
                # Gab's assistant reaches no memory of Dylan's: hippo2 on the
                # seat holds Dylan's.
                memory.command = "";
                harness = {
                  mcp = "/run/suki/mcp.json";
                  # An assistant: Libri's tools only, no shell or files.
                  coding = "0";
                };
                computer = {
                  run = "http://${computers.addr computers.indexes.suki}:${toString computers.runPort}";
                  runs = sukiDesk;
                };
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
        users.groups.yeoman-image = { };

        # The gateway runs as its own user so the seat's agents can neither
        # read its store and admin credential nor take over its proxy socket.
        users.users.libri-gateway = mkIf gateway.enable {
          isSystemUser = true;
          uid = gatewayUid;
          group = "libri-gateway";
          home = gatewayState;
        };
        users.groups.libri-gateway = mkIf gateway.enable { gid = gatewayGid; };
        # nginx reaches the gateway's proxy socket through its group.
        users.users.nginx.extraGroups = mkIf gateway.enable (singleton "libri-gateway");
        users.groups.${coreClientsGroup} = { };

        # Each serves its host itself: the chat at the root, the pages beside
        # it; the gateway serves `/v1` and the web view.
        shipProxy.routes =
          (
            (optionalAttrs legacy.enable { libri = config.libri.site.subdomain; } // { suki = "suki"; })
            |> mapAttrs (
              n: subdomain: {
                inherit subdomain;
                port = ports.${n};
                inherit proxyExtra;
              }
            )
          )
          // optionalAttrs gateway.enable (
            singleton gateway.subdomain ++ gateway.aliases
            |> map (
              subdomain:
              nameValuePair
                (if subdomain == gateway.subdomain then "libri-gateway" else "libri-gateway-${subdomain}")
                {
                  inherit subdomain;
                  inherit (gateway) port;
                  upstream = "http://unix:${gatewayProxySocket}";
                  inherit proxyExtra;
                }
            )
            |> listToAttrs
          );

        environment.etc."libri-core/libri.toml".source = coreSetup;
        users.users.${seat.user}.packages = coreCommands;
        environment.systemPackages = optionals gateway.enable (singleton gatewayCommand);
        # For login shells' own tools; the seat's commands carry the same
        # defaults for shells that read no session.
        environment.sessionVariables = coreEnvironment;

        # The gateway's store, there before its first start so an operator
        # can write the credential the unit waits for. StateDirectory= hands
        # a store the seat wrote before to the gateway's user at each start.
        # The add-ons' stores, the seat's alone, there before each first start.
        systemd.tmpfiles.settings.libri-addons = mkIf gateway.enable (
          servedAddons
          |> concatMap addonStores
          |> map (
            store:
            nameValuePair store {
              d = {
                user = seat.user;
                group = seat.user;
                mode = "0700";
              };
            }
          )
          |> listToAttrs
        );

        systemd.tmpfiles.settings.libri-gateway.${gatewayState}.d = mkIf gateway.enable {
          # The unit's own owner, which StateDirectory= would set anyway.
          user = "libri-gateway";
          group = "libri-gateway";
          mode = "0700";
        };

        systemd.tmpfiles.settings.yeoman-pages = {
          ${pages}.d = {
            user = "root";
            group = "root";
            mode = "0751";
          };
          "${pages}/suki".d = {
            user = "suki";
            group = "nginx";
            mode = "2750";
          };
        }
        // optionalAttrs legacy.enable {
          "${pages}/libri".d = {
            user = seat.user;
            group = "nginx";
            mode = "2750";
          };
        };

        # An instance's Libri build link and its add-on links live in a
        # directory the seat owns, and the seat restarts its units after
        # rebuilding the links.
        systemd.tmpfiles.settings.yeoman-builds = {
          "/var/lib/libri-build".d = {
            user = seat.user;
            group = seat.user;
            mode = "0755";
          };
          ${addonsBuild}.d = {
            user = seat.user;
            group = seat.user;
            mode = "0755";
          };
        };
        security.polkit.extraConfig =
          let
            managedUnits =
              optionals config.seat.hippo.enable (singleton "hippo.service")
              ++ optionals legacy.enable (singleton "libri.service")
              ++ [
                "libri-core.service"
                "suki.service"
              ]
              ++ optionals gateway.enable (
                singleton "libri-gateway.service" ++ map (name: "libri-addon-${name}.service") servedAddons
              )
              ++ optionals a2aServe (singleton "libri-addon-a2a.service");
          in
          ''
            polkit.addRule(function (action, subject) {
              if (action.id == "org.freedesktop.systemd1.manage-units" &&
                  [${
                    concatMapStringsSep ", " (unit: ''"${unit}"'') managedUnits
                  }].indexOf(action.lookup("unit")) >= 0 &&
                  ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0 &&
                  subject.user == "${seat.user}") {
                return polkit.Result.YES;
              }
            });
          '';

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
          libri-deploy.environment = {
            DEPLOY_LIBRI_ADDONS = concatStringsSep " " (attrNames addons);
            DEPLOY_LIBRI_SERVED_ADDONS = concatStringsSep " " (
              optionals gateway.enable servedAddons ++ optionals a2aServe (singleton "a2a")
            );
            DEPLOY_LIBRI_INSTANCES = concatStringsSep " " (
              optionals legacy.enable (singleton "libri:${toString ports.libri}")
              ++ singleton "suki:${toString ports.suki}"
            );
            DEPLOY_LIBRI_HIPPOS = concatStringsSep " " (optionals config.seat.hippo.enable (singleton "hippo"));
          }
          // optionalAttrs gateway.enable {
            DEPLOY_LIBRI_GATEWAY_PORT = toString gateway.port;
          };

          libri-core = {
            description = "Libri core for the seat";
            wantedBy = singleton "multi-user.target";
            restartIfChanged = false;
            unitConfig.ConditionFileIsExecutable = core;
            environment.PATH = mkForce seatPath;
            serviceConfig = {
              User = seat.user;
              Group = seat.user;
              WorkingDirectory = seat.home;
              # libri-clients so the core can give client.sock to the group.
              SupplementaryGroups = [
                "usage"
                coreClientsGroup
              ];
              LoadCredential = "claude-token:${config.secrets.agent-claude-token.path}";
              StateDirectory = "libri-core";
              StateDirectoryMode = "0700";
              RuntimeDirectory = "libri-core";
              # Search for libri-clients, whose group the core gives the
              # directory; it reaches client.sock alone, not owner.sock.
              RuntimeDirectoryMode = "0710";
              # Detached holders keep their sockets across a daemon stop and start.
              RuntimeDirectoryPreserve = true;
              # The seat's user scopes deny loopback MCP and sit outside work.slice.
              # Keep the holders in this cgroup and stop only the daemon.
              KillMode = "process";
              ExecStart = startCore;
              # systemd re-applies User:Group (bridge:bridge) to RuntimeDirectory
              # before spawning each ExecStartPost, which overwrote the core's own
              # chgrp to libri-clients; restore the group as the final post step.
              ExecStartPost = [
                "${getExe pkgs.curl} --fail --silent --output /dev/null --retry 12 --retry-all-errors --retry-delay 1 --max-time 1 --unix-socket ${coreSocket} http://localhost/v1/host"
                "${getExe' pkgs.coreutils "chgrp"} ${coreClientsGroup} ${coreRuntime}"
              ];
              Type = "exec";
              TimeoutStartSec = 20;
              Restart = "always";
              RestartSec = 10;
              LimitCORE = 0;
            };
          };

          # An up unit isn't a working Libri. This proves the active stack and
          # its memory; a failure here makes switcharoo roll the deploy back.
          libri-ready =
            if legacy.enable then
              {
                description = "Proves Bridge's Libri answers";
                wantedBy = singleton "multi-user.target";
                after = singleton "libri.service" ++ optionals config.seat.hippo.enable (singleton "hippo.service");
                restartTriggers =
                  singleton config.systemd.units."libri.service".unit
                  ++ optionals config.seat.hippo.enable (singleton config.systemd.units."hippo.service".unit);
                unitConfig.RequiresMountsFor = seat.hippo;
                environment.HIPPO_DIR = seat.hippo;
                path = [
                  pkgs.coreutils
                  pkgs.curl
                  pkgs.jq
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  User = seat.user;
                  TimeoutStartSec = 180;
                };
                script = ''
                  site=http://127.0.0.1:${toString ports.libri}/api/host
                  # Wait until Libri answers and its tool server is up. The tool
                  # server: the daemon checks it itself, as its credentials are in
                  # its own unit; tools is null while that runs, and a build older
                  # than the check has no such field and passes. A refused
                  # connection counts as not yet: a switch can restart Libri after
                  # the first answer, and a probe that stopped there rolled back
                  # healthy deploys.
                  for _ in $(seq 85); do
                    curl -fsS -m3 "$site" | jq -e '(has("tools") | not) or .tools == true' >/dev/null && break
                    sleep 1
                  done
                  curl -fsS -m3 "$site" | jq -e '(has("tools") | not) or .tools == true' >/dev/null
                  ${optionalString config.seat.hippo.enable ''
                    # hippo is Type=simple: "started" comes seconds before its socket.
                    for _ in $(seq 40); do
                      timeout 5 ${seat.libriBuild}/bin/hippo status >/dev/null && break
                      sleep 1
                    done
                    timeout 30 ${seat.libriBuild}/bin/hippo status >/dev/null
                  ''}
                '';
              }
            else
              {
                description = "Proves Bridge's Stage 2 Libri core, gateway and hippo2 answer";
                wantedBy = singleton "multi-user.target";
                after = [
                  "libri-core.service"
                  "hippo2.service"
                ]
                ++ optionals gateway.enable (singleton "libri-gateway.service");
                restartTriggers = [
                  config.systemd.units."libri-core.service".unit
                  config.systemd.units."hippo2.service".unit
                ]
                ++ optionals gateway.enable (singleton config.systemd.units."libri-gateway.service".unit);
                path = [
                  config.systemd.package
                  pkgs.coreutils
                  pkgs.curl
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  User = seat.user;
                  TimeoutStartSec = 180;
                };
                script = ''
                  for _ in $(seq 85); do
                    curl -fsS -m3 --unix-socket ${coreSocket} http://localhost/v1/host >/dev/null && break
                    sleep 1
                  done
                  curl -fsS -m3 --unix-socket ${coreSocket} http://localhost/v1/host >/dev/null
                  ${optionalString gateway.enable ''
                    for _ in $(seq 40); do
                      curl -fsS -m3 http://127.0.0.1:${toString gateway.port}/ >/dev/null && break
                      sleep 1
                    done
                    curl -fsS -m3 http://127.0.0.1:${toString gateway.port}/ >/dev/null
                  ''}
                  for _ in $(seq 40); do
                    systemctl is-active --quiet hippo2.service && break
                    sleep 1
                  done
                  systemctl is-active --quiet hippo2.service
                '';
              };

          suki = {
            description = "Suki, Gab's household assistant";
            # Like Libri, Suki reads unit changes at the next release.
            restartIfChanged = false;
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
        }
        // optionalAttrs legacy.enable {
          # The seat itself behind Libri's site: Bridge, on the seat's logins
          # and privileges, so none of the service's defaults apply.
          libri = {
            description = "Bridge in Dylan's web chat";
            # A restart ends every turn and worker under way, so a switch
            # leaves Libri running until libri-release restarts it with the
            # new unit configuration (seat/libri-deploy.mod.nix). Store
            # paths such as Chromium's change on nixpkgs updates.
            restartIfChanged = false;
            after =
              optionals config.seat.hippo.enable (singleton "hippo.service") ++ singleton "libri-core.service";
            wants =
              optionals config.seat.hippo.enable (singleton "hippo.service") ++ singleton "libri-core.service";
            environment =
              optionalAttrs (limits.server != null) { LIBRI_SERVER_CGROUP = limits.server; }
              // optionalAttrs (limits.harness != null) { LIBRI_HARNESS_CGROUP = limits.harness; }
              // optionalAttrs (limits.browser != null) { LIBRI_BROWSER_CGROUP = limits.browser; }
              // {
                # The seat's home-manager packages, its claude among them.
                PATH = mkForce seatPath;
                LIBRI_CORE_SOCKET = coreSocket;
                OPENCODE_CONFIG = toString openCodeConfig;
              };
            serviceConfig = {
              # No core dumps from what the workers run: a test browser that
              # crash-loops at start (13 Chromium dumps in six minutes, Nov 13)
              # sends each through systemd-coredump, whose slice peaked at 37 GB
              # beside the builds. Children inherit the limit.
              LimitCORE = 0;
              SupplementaryGroups = [
                "usage"
                "opencode-auth"
              ];
              LoadCredential = "claude-token:${config.secrets.agent-claude-token.path}";
              RuntimeDirectory = "libri";
              RuntimeDirectoryMode = "0700";
              ExecStartPre = claudeToken;
              EnvironmentFile = "-%t/%N/claude.env";
              WorkingDirectory = seat.home;
              NoNewPrivileges = false;
              ProtectSystem = false;
              PrivateTmp = false;
              # A restart ends the turn under way; the next message starts
              # afresh from the memory.
              Restart = "always";
              RestartSec = 10;
              # Each turn's claude and what it runs.
              MemoryHigh = "12G";
            };
          };
        }
        // optionalAttrs gateway.enable (
          addonUnits
          // {
            libri-gateway = {
              description = "Libri gateway: the core's /v1 for paired devices and the web view";
              wantedBy = singleton "multi-user.target";
              after = singleton "libri-core.service" ++ map (name: "libri-addon-${name}.service") servedAddons;
              wants = singleton "libri-core.service" ++ map (name: "libri-addon-${name}.service") servedAddons;
              unitConfig = {
                ConditionFileIsExecutable = "${seat.libriBuild}/bin/libri-gateway";
                # A build before Libri 0.9.119 carries no web view.
                ConditionPathExists = [
                  gatewayToken
                  "${gatewayWeb}/index.html"
                ];
              };
              environment = gatewayEnvironment;
              serviceConfig = lib.ship.hardened.tenant // {
                User = "libri-gateway";
                # Its own group, not nginx's, which can read the proxy's TLS
                # keys; nginx joins this one to reach the 0660 proxy socket.
                Group = "libri-gateway";
                SupplementaryGroups = singleton coreClientsGroup;
                # The proxy's SO_PEERCRED must carry nginx's real UID for
                # --proxy-uid to match.
                PrivateUsers = false;
                StateDirectory = "libri-gateway";
                StateDirectoryMode = "0700";
                RuntimeDirectory = "libri-gateway";
                RuntimeDirectoryMode = "0750";
                ExecStart = gatewayServe;
                # The core's socket, tailscaled's LocalAPI, the proxy and add-on
                # sockets, and netlink, by which Iroh follows the host's
                # interfaces.
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_NETLINK"
                  "AF_INET"
                  "AF_INET6"
                ];
                # Iroh's QUIC binds UDP; any UDP port, since Iroh picks its own.
                SocketBindAllow = [
                  "tcp:${toString gateway.port}"
                  "udp"
                ];
                # The proxy and the tailnet in, and the internet out for pushes;
                # not the LAN or the seat's loopback addresses.
                IPAddressAllow = fences.loopback ++ singleton fences.tailnet;
                IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
                Restart = "always";
                RestartSec = 10;
              };
            };
          }
        )
        // optionalAttrs a2aServe {
          libri-addon-a2a = {
            description = "Libri's inbound A2A peer receiver";
            wantedBy = singleton "multi-user.target";
            after = singleton "libri-core.service";
            wants = singleton "libri-core.service";
            unitConfig = {
              ConditionFileIsExecutable = addonBinary "a2a";
              ConditionPathExists = [
                a2aPeersFile
                a2aCfg.coreTokenFile
              ];
            };
            serviceConfig = lib.ship.hardened.tenant // {
              User = seat.user;
              Group = seat.user;
              SupplementaryGroups = singleton coreClientsGroup;
              PrivateUsers = false;
              # ProtectSystem=strict already keeps /var/lib/libri-core read-only
              # without bind-mounting individual files across atomic renames.
              ExecStart = escapeShellArgs (
                [
                  (addonBinary "a2a")
                  "serve"
                  "--listen"
                  a2aCfg.listen
                  "--peers-file"
                  a2aPeersFile
                  "--core-socket"
                  coreClients
                  "--core-token-file"
                  a2aCfg.coreTokenFile
                ]
                ++ optionals (a2aName != null) [
                  "--name"
                  a2aName
                ]
                ++ optionals (a2aCfg.person != null) [
                  "--person"
                  a2aCfg.person
                ]
              );
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
              SocketBindAllow = "tcp:${a2aPort}";
              IPAddressAllow = fences.loopback;
              IPAddressDeny = "any";
              Restart = "always";
              RestartSec = 10;
            };
          };
        };
      };
    };
}
