# Libri on Water: one Stage 2 assistant per person (`libri.assistants.<name>`),
# each running its own core daemon, gateway, and per-assistant add-ons on the
# shared release links at `seat.libriBuild` and `seat.libriAddonsBuild`, which
# `deploy_libri.sh` moves on release so a Libri change needs no switch here.
#
# Each assistant keeps every word of its prompts on disk in its person layer
# (`~/.config/libri-core/AGENTS.md` or `configDir`), never in monix.
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
        any
        concatLists
        concatMap
        elem
        filter
        last
        optionals
        singleton
        sort
        toList
        unique
        ;
      inherit (lib.meta) getExe getExe';
      inherit (lib.modules) mkForce mkIf mkMerge;
      inherit (lib.options) mkOption;
      inherit (lib.strings)
        concatMapStringsSep
        concatStringsSep
        escapeShellArg
        escapeShellArgs
        hasPrefix
        hasSuffix
        optionalString
        readFile
        removePrefix
        splitString
        ;
      inherit (lib) types;
      inherit (lib.ship) fences topology;

      seat = topology.seat;
      core = "${seat.libriBuild}/bin/libri-core";
      addonsBuild = seat.libriAddonsBuild;
      addonBinary = name: "${addonsBuild}/${name}/bin/libri-${name}";
      # Server-sent events stream as they come; uploads match the web view's cap.
      proxyExtra = "proxy_buffering off; client_max_body_size 100m;";

      tomlFormat = pkgs.formats.toml { };
      libriPackages = inputs.libri.packages.${pkgs.stdenv.hostPlatform.system} or { };

      # Standard stdio MCP add-ons packaged individually in the Libri flake.
      stdAddonNames = [
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
        "computer"
      ];

      # Add-ons that also serve HTTP over a Unix socket to a gateway.
      servedAddonNames = [
        "boards"
        "pages"
        "lists"
        "files"
        "speech"
        "layout"
      ];

      # The web view ships in the deployed build beside the gateway, so the two
      # always move in one release.
      gatewayWeb = "${seat.libriBuild}/web";

      # A program on a user's PATH with its service's settings as defaults, in
      # any shell, login or not, so a command reaches the store and daemon the
      # service does.
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

      # The seat's MCP servers (minus web and hippo2, which are wired on their
      # own), plus hob and money when enabled on the host. Only an assistant
      # with `core.includeSeatMcp = true` (Bridge) receives these.
      moneyMcp = optionalAttrs (config.systemd.services ? money) {
        money = {
          type = "http";
          url = "http://127.0.0.1:${toString config.money.mcpPort}/mcp";
        };
      };
      seatServers =
        removeAttrs config.seat.mcpServers [
          "web"
          "hippo2"
        ]
        // optionalAttrs (config.services ? hob && config.services.hob.enable) {
          hob = {
            type = "http";
            url = "http://127.0.0.1:${toString config.services.hob.port}/mcp";
          };
        }
        // moneyMcp;
      seatCoreServers =
        (
          seatServers
          |> mapAttrs (
            _: server:
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
          hippo2 = {
            command = [
              (getExe config.services.hippo2.finalPackage)
              "mcp"
            ];
            env = {
              HIPPO_DIR = seat.hippo;
              LIBRI_SOCKET.session = "socket";
              LIBRI_TOKEN.session = "token";
              LIBRI_SESSION.session = "id";
            };
          };
        };

      # The resolver on loopback and the internet for outbound HTTPS; not the
      # tailnet, the LAN or the seat's loopback address.
      fence = {
        IPAddressAllow = fences.loopback;
        IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
      };

      # STAGE 2 ASSISTANTS

      enabledAssistants = config.libri.assistants |> filterAttrs (_: assistant: assistant.enable);

      # Submodule for one independent Stage 2 assistant.
      hostConfig = config;
      assistantModule =
        { name, config, ... }:
        let
          acfg = config;
        in
        {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Enable this Stage 2 Libri assistant.";
            };
            unitPrefix = mkOption {
              type = types.str;
              default = name;
              description = "Prefix for systemd units, runtime/state directories, and default system config directory.";
            };
            description = mkOption {
              type = types.str;
              default = "Libri core for ${name}";
              description = "Description for the core systemd unit.";
            };
            user = mkOption {
              type = types.str;
              default = name;
              description = "Unix account that runs the core daemon and its add-ons.";
            };
            group = mkOption {
              type = types.str;
              default = acfg.user;
              description = "Unix group for the core daemon and its add-ons.";
            };
            createUser = mkOption {
              type = types.bool;
              default = false;
              description = "Declare `users.users.<user>` and `users.groups.<group>` as a system account for this assistant.";
            };
            uid = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Optional static numeric UID when `createUser` is enabled.";
            };
            gid = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Optional static numeric GID when `createUser` is enabled.";
            };
            userHome = mkOption {
              type = types.str;
              default = acfg.home;
              description = "Home directory recorded in `/etc/passwd` when `createUser` is enabled.";
            };
            home = mkOption {
              type = types.str;
              default = acfg.dataDir;
              description = "Working directory for the core daemon.";
            };
            dataDir = mkOption {
              type = types.str;
              default = "/var/lib/${acfg.unitPrefix}-core";
              description = "State directory for `libri-core` (must live under `/var/lib/`).";
            };
            runtimeDir = mkOption {
              type = types.str;
              default = "/run/${acfg.unitPrefix}-core";
              description = "Runtime directory for `libri-core` sockets (must live under `/run/`).";
            };
            socketPath = mkOption {
              type = types.str;
              default = "${acfg.runtimeDir}/owner.sock";
              readOnly = true;
              description = "Owner Unix socket path for `libri-core`.";
            };
            clientSocketPath = mkOption {
              type = types.str;
              default = "${acfg.runtimeDir}/client.sock";
              readOnly = true;
              description = "Client Unix socket path for `libri-core`.";
            };
            clientsGroup = mkOption {
              type = types.str;
              default = "${acfg.unitPrefix}-clients";
              description = "Group granted access to `client.sock`.";
            };
            systemConfigDir = mkOption {
              type = types.str;
              default = "/etc/${acfg.unitPrefix}-core";
              description = "Deployment layer directory holding `libri.toml` (must live under `/etc/`).";
            };
            configDir = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Optional person layer directory (`LIBRI_CONFIG_DIR`). When null, `libri-core` reads `$XDG_CONFIG_HOME/libri-core`.";
            };
            hippo2Unit = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Optional hippo2 systemd unit verified by `${acfg.unitPrefix}-ready.service`.";
            };
            installUserCommands = mkOption {
              type = types.bool;
              default = true;
              description = "Install wrapped core and add-on CLI commands into `users.users.<user>.packages`.";
            };
            setSessionVariables = mkOption {
              type = types.bool;
              default = false;
              description = "Export `LIBRI_RUNTIME_DIR` and `LIBRI_DATA_DIR` in `environment.sessionVariables`.";
            };

            core = {
              locked = mkOption {
                type = types.bool;
                default = false;
                description = "Lock the deployment layer in `libri.toml` so the person layer cannot widen capabilities, override `mcp`/`clients`, or replace deployment skills.";
              };
              includeSeatMcp = mkOption {
                type = types.bool;
                default = false;
                description = "Include the seat's shared MCP servers (`browse`, `cloudflare`, `hob`, `money`, seat `hippo2`). Keep false for isolated assistants.";
              };
              path = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Explicit `PATH` for the core service (controls which harness binaries are visible).";
              };
              harnesses = mkOption {
                type = types.attrsOf (
                  types.submodule {
                    options = {
                      child_mode = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Permission mode granted to cross-harness child sessions.";
                      };
                      tools = mkOption {
                        type = types.nullOr (types.listOf types.str);
                        default = null;
                        description = "Allow-list of built-in harness tools (e.g. `[\"AskUserQuestion\"]`); null leaves all built-in tools enabled.";
                      };
                      strict_mcp = mkOption {
                        type = types.nullOr types.bool;
                        default = null;
                        description = "Restrict harness to MCP servers declared by the core (`--strict-mcp-config`).";
                      };
                      acp = mkOption {
                        type = types.listOf types.str;
                        default = [ ];
                        description = "Command vector for an Agent Client Protocol harness.";
                      };
                    };
                  }
                );
                default = { };
                description = "Per-harness configuration written under `[harness.<name>]` in `libri.toml`.";
              };
              mcpServers = mkOption {
                type = types.attrsOf tomlFormat.type;
                default = { };
                description = "Additional MCP servers merged under `[mcp.<name>]` in `libri.toml`.";
              };
              extraEnv = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Extra environment variables set on the core systemd service.";
              };
              envCredentials = mkOption {
                type = types.attrsOf (
                  types.submodule {
                    options = {
                      credentialName = mkOption {
                        type = types.str;
                        description = "Name under `$CREDENTIALS_DIRECTORY` (systemd `LoadCredential`).";
                      };
                      path = mkOption {
                        type = types.str;
                        description = "Host secret file path passed to systemd `LoadCredential`.";
                      };
                    };
                  }
                );
                default = { };
                description = "Secrets loaded via systemd `LoadCredential` and exported as environment variables before exec'ing `libri-core`.";
              };
              authHeaderFiles = mkOption {
                type = types.attrsOf (
                  types.submodule {
                    options = {
                      credentialName = mkOption {
                        type = types.str;
                        description = "Name under `$CREDENTIALS_DIRECTORY` (systemd `LoadCredential`).";
                      };
                      path = mkOption {
                        type = types.str;
                        description = "Host secret file path passed to systemd `LoadCredential`.";
                      };
                      prefix = mkOption {
                        type = types.str;
                        default = "Bearer ";
                        description = "Prefix written before the trimmed secret value.";
                      };
                    };
                  }
                );
                default = { };
                description = "Secrets loaded via systemd `LoadCredential` and rendered as mode-0600 files under `runtimeDir` for `libri.toml` `{ file = ... }` headers.";
              };
              extraLoadCredentials = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Additional raw `LoadCredential` entries on the core service.";
              };
              supplementaryGroups = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Extra supplementary groups for the core service (besides `clientsGroup`).";
              };
              keepHoldersAcrossRestart = mkOption {
                type = types.bool;
                default = true;
                description = "Keep session holder processes alive across core daemon restarts (`KillMode=process`); set false for `KillMode=control-group`.";
              };
              extraServiceConfig = mkOption {
                type = types.attrsOf types.anything;
                default = { };
                description = "Additional systemd `serviceConfig` settings merged onto the core service.";
              };
            };

            bootstrap = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = "Run `<prefix>-bootstrap.service` to mint missing core credentials and ensure an open main session.";
              };
              hippo2TokenFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Optional token file minted with `read` scope (`reach: all`) for this assistant's hippo2 instance.";
              };
              hippo2Owner = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Ownership (`user:group`) applied to `hippo2TokenFile` when minted.";
              };
              mainSession = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      harness = mkOption {
                        type = types.str;
                        description = "Harness for the default `role=main` session.";
                      };
                      cwd = mkOption {
                        type = types.str;
                        description = "Working directory for the default `role=main` session.";
                      };
                      mode = mkOption {
                        type = types.str;
                        description = "Permission mode for the default `role=main` session.";
                      };
                    };
                  }
                );
                default = null;
                description = "When set, ensure an open `role=main` session exists during bootstrap.";
              };
            };

            gateway = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = "Run `libri-gateway` against this assistant's core.";
              };
              port = mkOption {
                type = types.port;
                default = 8953;
                description = "Loopback TCP port the gateway listens on for direct clients and health checks.";
              };
              listen = mkOption {
                type = types.str;
                default = "127.0.0.1:${toString acfg.gateway.port}";
                description = "Address the gateway binds for direct clients; the proxy uses its Unix socket.";
              };
              subdomain = mkOption {
                type = types.str;
                default = if acfg.unitPrefix == "libri" then "core" else acfg.unitPrefix;
                description = "Primary subdomain under `shipProxy.domain`.";
              };
              domain = mkOption {
                type = types.str;
                default = "${acfg.gateway.subdomain}.${hostConfig.shipProxy.domain}";
                description = "Public hostname of the gateway (used for `LIBRI_GATEWAY_URL`).";
              };
              aliases = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Further subdomains under `shipProxy.domain` that also serve this gateway.";
              };
              tailnetOwners = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Tailscale `login` or `login/device` entries admitted via `--tailnet-whois` (passed as repeated `--tailnet-owner`).";
              };
              assistantName = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Assistant name injected into served `index.html` via `<meta name=\"assistant\">` (`LIBRI_GATEWAY_ASSISTANT_NAME`).";
              };
              uiMode = mkOption {
                type = types.enum [
                  "full"
                  "simple"
                ];
                default = "full";
                description = "Web UI presentation mode (`LIBRI_GATEWAY_UI_MODE=simple` when `simple`; omitted for `full`).";
              };
              iroh = mkOption {
                type = types.bool;
                default = true;
                description = "Pass `--iroh` to `libri-gateway serve` for Iroh QUIC relay access beside the tailnet.";
              };
              user = mkOption {
                type = types.str;
                default = "${acfg.unitPrefix}-gateway";
                description = "System user running the gateway.";
              };
              group = mkOption {
                type = types.str;
                default = "${acfg.unitPrefix}-gateway";
                description = "System group running the gateway (nginx joins it to reach `proxy.sock`).";
              };
              uid = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "Static numeric UID for the gateway user (required when served add-ons enforce `--peer-uid`).";
              };
              gid = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "Optional static numeric GID for the gateway group.";
              };
            };

            a2a = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = "Run the inbound A2A HTTP receiver (`libri-a2a serve`) for this assistant.";
              };
              port = mkOption {
                type = types.nullOr types.port;
                default = null;
                description = "Loopback TCP port for the inbound A2A receiver.";
              };
              listen = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Explicit loopback `host:port` override (defaults to `127.0.0.1:<port>`).";
              };
              peersFile = mkOption {
                type = types.str;
                default = "${acfg.dataDir}/a2a-peers.json";
                description = "JSON file mapping peer names to inbound tokens.";
              };
              tokenFile = mkOption {
                type = types.str;
                default = "${acfg.dataDir}/a2a.token";
                description = "File holding the non-approve core credential (`read,operate`, `reach: all`) for inbound A2A delivery.";
              };
              session = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Optional target session id (`--session`); defaults to the active `role=main` session.";
              };
              name = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Assistant name advertised in the inbound A2A Agent Card.";
              };
              person = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Person name advertised in the inbound A2A Agent Card.";
              };
            };

            addons =
              genAttrs stdAddonNames (addonName: {
                enable = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Give this assistant's sessions the `${addonName}` add-on.";
                };
                environment = mkOption {
                  type = types.attrsOf types.str;
                  default = { };
                  description = "Environment variables for `libri-${addonName}`.";
                };
              })
              |> recursiveUpdate {
                speech.provider = mkOption {
                  type = types.enum [
                    "local"
                    "openai"
                  ];
                  default = "local";
                  description = "Speech provider: `local` (host models, offline) or `openai` (OpenAI-compatible HTTPS endpoint).";
                };
                wiki = {
                  enable = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Give this assistant's sessions the `wiki` Obsidian vault MCP server.";
                  };
                  dir = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "Obsidian vault directory served by `wiki serve DIR`.";
                  };
                  readOnly = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Pass `--read-only` to `wiki serve`.";
                  };
                };
                yeomanImage = {
                  enable = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Give this assistant's sessions the household `yeoman-image-mcp` server backed by `/run/yeoman-image.sock`.";
                  };
                  dir = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "Directory where generated PNG images are saved.";
                  };
                };
                connect = {
                  enable = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Enable `libri-connect` remote MCP relays, CLI wrapper, and OAuth renewal timer.";
                  };
                  dir = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "Directory holding connections and OAuth sign-ins (`LIBRI_CONNECT_DIR`).";
                  };
                  environment = mkOption {
                    type = types.attrsOf types.str;
                    default = { };
                    description = "Additional environment variables for `libri-connect`.";
                  };
                  servers = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Named remote connections exposed as `[mcp.<name>]` via `libri-connect serve <name>` with core approvals.";
                  };
                  renew = {
                    enable = mkOption {
                      type = types.bool;
                      default = true;
                      description = "Run a systemd timer calling `libri-connect renew` to keep OAuth refresh tokens fresh.";
                    };
                    interval = mkOption {
                      type = types.str;
                      default = "10min";
                      description = "Interval between renewal runs (`OnUnitActiveSec`).";
                    };
                  };
                };
              };
          };
        };

      # Build all NixOS config fragments for one enabled Stage 2 assistant.
      mkAssistant =
        name: assistant:
        let
          prefix = assistant.unitPrefix;
          coreUnit = "${prefix}-core";
          gatewayUnit = "${prefix}-gateway";
          gw = assistant.gateway;
          gwState = "/var/lib/${prefix}-gateway";
          gwToken = "${gwState}/admin.token";
          gwProxySocket = "/run/${prefix}-gateway/proxy.sock";
          gwDomain = gw.domain;

          enabledStdAddons =
            assistant.addons |> filterAttrs (addonName: addon: elem addonName stdAddonNames && addon.enable);
          speechLocal = assistant.addons.speech.provider == "local";
          connectCfg = assistant.addons.connect;
          wikiCfg = assistant.addons.wiki;
          yeomanImageCfg = assistant.addons.yeomanImage;
          connectDir =
            if connectCfg.dir != null then connectCfg.dir else connectCfg.environment.LIBRI_CONNECT_DIR or null;

          addonEnvironment =
            addonName:
            if addonName == "connect" then
              connectCfg.environment // optionalAttrs (connectDir != null) { LIBRI_CONNECT_DIR = connectDir; }
            else
              assistant.addons.${addonName}.environment
              // optionalAttrs (addonName == "speech") (
                {
                  LIBRI_SPEECH_PROVIDER = assistant.addons.speech.provider;
                }
                // optionalAttrs (speechLocal && libriPackages ? speech-models) {
                  LIBRI_SPEECH_MODELS_DIR = "${libriPackages.speech-models}";
                }
              );

          servedAddons = servedAddonNames |> filter (addonName: enabledStdAddons ? ${addonName});
          addonSocket = addonName: "/run/${prefix}-addons/${addonName}/${addonName}.sock";
          addonStores =
            addonName:
            assistant.addons.${addonName}.environment
            |> filterAttrs (variable: _: hasSuffix "_DIR" variable || hasSuffix "_STATE" variable)
            |> attrValues;
          addonCredentials =
            addonName:
            assistant.addons.${addonName}.environment
            |> filterAttrs (variable: _: hasSuffix "_TOKEN_FILE" variable)
            |> attrValues;
          addonCallsOut = addonName: addonName == "speech" && !speechLocal;

          a2aCfg = assistant.a2a;
          a2aServe = a2aCfg.enable;
          a2aListen = if a2aCfg.listen != null then a2aCfg.listen else "127.0.0.1:${toString a2aCfg.port}";
          a2aPort = last (splitString ":" a2aListen);
          a2aName =
            if a2aCfg.name != null then
              a2aCfg.name
            else
              assistant.addons.a2a.environment.LIBRI_A2A_NAME or null;

          renderedHarnesses =
            assistant.core.harnesses
            |> mapAttrs (
              _: h:
              optionalAttrs (h.child_mode != null) { inherit (h) child_mode; }
              // optionalAttrs (h.tools != null) { inherit (h) tools; }
              // optionalAttrs (h.strict_mcp != null) { inherit (h) strict_mcp; }
              // optionalAttrs (h.acp != [ ]) { inherit (h) acp; }
            );

          connectMcpServers =
            if connectCfg.enable then
              connectCfg.servers
              |> map (
                serverName:
                nameValuePair serverName {
                  command = [
                    (addonBinary "connect")
                    "serve"
                    serverName
                  ];
                  env = addonEnvironment "connect" // {
                    LIBRI_ASK = "core";
                    LIBRI_SOCKET.session = "socket";
                    LIBRI_TOKEN.session = "token";
                    LIBRI_SESSION.session = "id";
                  };
                }
              )
              |> listToAttrs
            else
              { };

          wikiMcpServer = optionalAttrs (wikiCfg.enable && wikiCfg.dir != null) {
            wiki.command = [
              "${seat.libriBuild}/bin/wiki"
              "serve"
              wikiCfg.dir
            ]
            ++ optionals wikiCfg.readOnly (singleton "--read-only");
          };

          yeomanImageMcpServer = optionalAttrs (yeomanImageCfg.enable && yeomanImageCfg.dir != null) {
            image.command = [
              (getExe image)
              yeomanImageCfg.dir
            ];
          };

          stdAddonMcpServers =
            enabledStdAddons
            |> mapAttrs (
              addonName: _:
              {
                command = singleton (addonBinary addonName);
              }
              // optionalAttrs (addonEnvironment addonName != { }) { env = addonEnvironment addonName; }
            );

          coreSetup = tomlFormat.generate "${coreUnit}.toml" (
            optionalAttrs assistant.core.locked { locked = true; }
            // {
              clients = {
                mode = "0660";
                group = assistant.clientsGroup;
              };
            }
            // optionalAttrs (renderedHarnesses != { }) { harness = renderedHarnesses; }
            // {
              mcp =
                optionalAttrs assistant.core.includeSeatMcp seatCoreServers
                // wikiMcpServer
                // yeomanImageMcpServer
                // connectMcpServers
                // stdAddonMcpServers
                // assistant.core.mcpServers;
            }
          );

          coreEnvironment = {
            LIBRI_RUNTIME_DIR = assistant.runtimeDir;
            LIBRI_DATA_DIR = assistant.dataDir;
          }
          // optionalAttrs (assistant.systemConfigDir != "/etc/libri-core") {
            LIBRI_SYSTEM_CONFIG_DIR = assistant.systemConfigDir;
          }
          // optionalAttrs (assistant.configDir != null) {
            LIBRI_CONFIG_DIR = assistant.configDir;
          };

          credLines =
            assistant.core.envCredentials
            |> mapAttrsToList (
              var: cred: ''
                ${var}=$(< "$CREDENTIALS_DIRECTORY/${cred.credentialName}") || exit 1
                export ${var}
              ''
            )
            |> concatStringsSep "";

          authHeaderLines =
            assistant.core.authHeaderFiles
            |> mapAttrsToList (
              fileName: cred: ''
                (umask 077 && printf '%s%s\n' ${escapeShellArg cred.prefix} "$(${getExe' pkgs.coreutils "tr"} -d '\r\n' < "$CREDENTIALS_DIRECTORY/${cred.credentialName}")" > ${escapeShellArg "${assistant.runtimeDir}/${fileName}"}) || exit 1
              ''
            )
            |> concatStringsSep "";

          startCore = pkgs.writeShellScript "start-${coreUnit}" ''
            ${credLines}${authHeaderLines}exec ${core} --runtime-dir ${escapeShellArg assistant.runtimeDir} --data-dir "$STATE_DIRECTORY" daemon --no-holder-scope
          '';

          loadCredentials =
            (assistant.core.envCredentials |> mapAttrsToList (_: cred: "${cred.credentialName}:${cred.path}"))
            ++ (
              assistant.core.authHeaderFiles |> mapAttrsToList (_: cred: "${cred.credentialName}:${cred.path}")
            )
            ++ assistant.core.extraLoadCredentials;

          gatewayEnvironment = {
            LIBRI_SOCKET = assistant.clientSocketPath;
            LIBRI_GATEWAY_STATE = "${gwState}/gateway.sqlite";
            LIBRI_GATEWAY_TOKEN_FILE = gwToken;
            LIBRI_GATEWAY_URL = "https://${gwDomain}";
          };

          gatewayServe = escapeShellArgs (
            [
              "${seat.libriBuild}/bin/libri-gateway"
              "serve"
              "--listen"
              gw.listen
              "--web-dir"
              gatewayWeb
              "--proxy-socket"
              gwProxySocket
              "--proxy-uid"
              (toString config.ids.uids.nginx)
            ]
            # Layer 2 beside the tailnet: paired devices reach the gateway over
            # Iroh QUIC through n0's public relays.
            ++ optionals gw.iroh (singleton "--iroh")
            ++ (
              servedAddons
              |> concatMap (addonName: [
                "--addon"
                "${addonName}=${addonSocket addonName}"
              ])
            )
            ++ optionals (gw.tailnetOwners != [ ]) (
              singleton "--tailnet-whois"
              ++ (
                gw.tailnetOwners
                |> concatMap (owner: [
                  "--tailnet-owner"
                  owner
                ])
              )
            )
          );

          gatewayCommand = pkgs.writeShellScriptBin gatewayUnit (
            (
              [
                ''if [ "$(${pkgs.coreutils}/bin/id -un)" != ${gw.user} ]; then''
                ''exec /run/wrappers/bin/sudo -u ${gw.user} -- "$0" "$@"''
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

          coreCliName = if prefix == "libri" then "libri" else "${prefix}-core";
          addonCliName =
            addonName: if prefix == "libri" then "libri-${addonName}" else "${prefix}-${addonName}";
          cliAddons = attrNames enabledStdAddons ++ optionals connectCfg.enable (singleton "connect");
          coreCommands = [
            (seatCommand coreCliName coreEnvironment core)
          ]
          ++ (
            cliAddons
            |> map (
              addonName: seatCommand (addonCliName addonName) (addonEnvironment addonName) (addonBinary addonName)
            )
          );

          addonUnits =
            servedAddons
            |> map (
              addonName:
              nameValuePair "${prefix}-addon-${addonName}" {
                description = "${
                  if prefix == "libri" then "Libri's" else "${prefix}'s"
                } ${addonName} add-on, served to the gateway over HTTP";
                wantedBy = singleton "multi-user.target";
                before = singleton "${gatewayUnit}.service";
                unitConfig = {
                  ConditionFileIsExecutable = addonBinary addonName;
                }
                // optionalAttrs (addonCredentials addonName != [ ]) {
                  ConditionPathExists = addonCredentials addonName;
                };
                environment = addonEnvironment addonName;
                serviceConfig = lib.ship.hardened.tenant // {
                  User = assistant.user;
                  # The gateway's group reaches the 0660 socket; no one else does.
                  Group = gw.group;
                  # SO_PEERCRED must carry the gateway's real UID for --peer-uid.
                  PrivateUsers = false;
                  RuntimeDirectory = "${prefix}-addons/${addonName}";
                  RuntimeDirectoryMode = "0750";
                  ReadWritePaths = addonStores addonName;
                  ExecStart = escapeShellArgs [
                    (addonBinary addonName)
                    "serve"
                    "--http-socket"
                    (addonSocket addonName)
                    "--peer-uid"
                    (toString gw.uid)
                  ];
                  RestrictAddressFamilies = [
                    "AF_UNIX"
                  ]
                  ++ optionals (addonCallsOut addonName) [
                    "AF_INET"
                    "AF_INET6"
                  ];
                  IPAddressDeny = if addonCallsOut addonName then fences.internetOnlyDeny else "any";
                  # ONNX Runtime reads /proc/cpuinfo to size its threads to the
                  # host's cores; the tenant default hides it.
                  ProcSubset =
                    if addonName == "speech" && speechLocal then "all" else lib.ship.hardened.tenant.ProcSubset;
                  Restart = "always";
                  RestartSec = 10;
                };
              }
            )
            |> listToAttrs;

          etcRelPath = "${removePrefix "/etc/" assistant.systemConfigDir}/libri.toml";
          stateDirRel = removePrefix "/var/lib/" assistant.dataDir;

          coreExtraServiceConfig =
            assistant.core.extraServiceConfig
            // optionalAttrs ((assistant.core.extraServiceConfig.ProtectSystem or null) != null) {
              ReadWritePaths =
                toList (assistant.core.extraServiceConfig.ReadWritePaths or [ ]) ++ singleton assistant.runtimeDir;
            };

          restrictedHarness = any (h: h.strict_mcp == true || h.tools != null) (
            attrValues assistant.core.harnesses
          );
          rootOwnedConfigDir = assistant.configDir != null && !(hasPrefix "/etc/" assistant.configDir);
          pathInside = outer: inner: inner == outer || hasPrefix "${outer}/" inner;

          assistantUserAttrs =
            optionalAttrs assistant.createUser (
              {
                isSystemUser = true;
                inherit (assistant) group;
                home = assistant.userHome;
              }
              // optionalAttrs (assistant.uid != null) { inherit (assistant) uid; }
            )
            // optionalAttrs assistant.installUserCommands {
              packages = coreCommands;
            };

          extraStateStores =
            optionals (wikiCfg.enable && wikiCfg.dir != null && hasPrefix "${assistant.dataDir}/" wikiCfg.dir) (
              singleton wikiCfg.dir
            )
            ++ optionals (
              assistant.addons.computer.enable && assistant.addons.computer.environment ? LIBRI_OUTBOX_DIR
            ) (singleton assistant.addons.computer.environment.LIBRI_OUTBOX_DIR);
        in
        {
          assertions = [
            {
              assertion = hasPrefix "/var/lib/" assistant.dataDir;
              message = "libri.assistants.${name}.dataDir must live under /var/lib/.";
            }
            {
              assertion = hasPrefix "/run/" assistant.runtimeDir;
              message = "libri.assistants.${name}.runtimeDir must live under /run/.";
            }
            {
              assertion = hasPrefix "/etc/" assistant.systemConfigDir;
              message = "libri.assistants.${name}.systemConfigDir must live under /etc/.";
            }
            {
              assertion =
                assistant.configDir == null
                || hasPrefix "/etc/" assistant.configDir
                || hasPrefix "/var/lib/" assistant.configDir;
              message = "libri.assistants.${name}.configDir must live under /etc/ or /var/lib/.";
            }
            {
              assertion =
                !restrictedHarness
                || (
                  assistant.configDir != null
                  && !(pathInside assistant.dataDir assistant.configDir)
                  && !(pathInside assistant.home assistant.configDir)
                  && !(pathInside assistant.userHome assistant.configDir)
                );
              message = "libri.assistants.${name}: restricted harnesses require a root-owned configDir outside dataDir and home so the assistant cannot write person-layer libri.toml.";
            }
            {
              assertion = !(gw.enable && servedAddons != [ ] && gw.uid == null);
              message = "libri.assistants.${name}.gateway.uid must be set when served add-ons enforce --peer-uid.";
            }
            {
              assertion = !(a2aServe && a2aCfg.port == null && a2aCfg.listen == null);
              message = "libri.assistants.${name}.a2a requires `port` or `listen` when enabled.";
            }
            {
              assertion = !(connectCfg.enable && connectDir == null);
              message = "libri.assistants.${name}.addons.connect requires `dir` or `environment.LIBRI_CONNECT_DIR` when enabled.";
            }
            {
              assertion = !(yeomanImageCfg.enable && yeomanImageCfg.dir == null);
              message = "libri.assistants.${name}.addons.yeomanImage requires `dir` when enabled.";
            }
            {
              assertion =
                !(
                  assistant.bootstrap.enable
                  && assistant.bootstrap.hippo2TokenFile != null
                  && assistant.bootstrap.hippo2Owner == null
                );
              message = "libri.assistants.${name}.bootstrap.hippo2Owner must be set when hippo2TokenFile is set.";
            }
          ];

          users.groups = {
            ${assistant.clientsGroup} = { };
          }
          // optionalAttrs assistant.createUser {
            ${assistant.group} = optionalAttrs (assistant.gid != null) { inherit (assistant) gid; };
          }
          // optionalAttrs gw.enable {
            ${gw.group} = optionalAttrs (gw.gid != null) { inherit (gw) gid; };
          };

          users.users =
            optionalAttrs gw.enable {
              ${gw.user} = {
                isSystemUser = true;
                inherit (gw) group;
                home = gwState;
              }
              // optionalAttrs (gw.uid != null) { inherit (gw) uid; };
              nginx.extraGroups = singleton gw.group;
            }
            // optionalAttrs (assistantUserAttrs != { }) {
              ${assistant.user} = assistantUserAttrs;
            };

          environment.etc.${etcRelPath}.source = coreSetup;
          environment.systemPackages = optionals gw.enable (singleton gatewayCommand);
          environment.sessionVariables = mkIf assistant.setSessionVariables coreEnvironment;

          shipProxy.routes = optionalAttrs gw.enable (
            singleton gw.subdomain ++ gw.aliases
            |> map (
              subdomain:
              nameValuePair (if subdomain == gw.subdomain then gatewayUnit else "${gatewayUnit}-${subdomain}") {
                inherit subdomain;
                inherit (gw) port;
                upstream = "http://unix:${gwProxySocket}";
                inherit proxyExtra;
              }
            )
            |> listToAttrs
          );

          systemd.tmpfiles.settings =
            optionalAttrs ((gw.enable && servedAddons != [ ]) || extraStateStores != [ ]) {
              "${prefix}-addons" =
                (
                  singleton assistant.dataDir
                  ++ optionals gw.enable (servedAddons |> concatMap addonStores)
                  ++ extraStateStores
                )
                |> unique
                |> map (
                  store:
                  nameValuePair store {
                    d = {
                      inherit (assistant) user group;
                      mode = "0700";
                    };
                  }
                )
                |> listToAttrs;
            }
            // optionalAttrs rootOwnedConfigDir {
              "${prefix}-config".${assistant.configDir}.d = {
                user = "root";
                group = assistant.group;
                mode = "0750";
              };
            }
            // {
              # Managed by tmpfiles rather than RuntimeDirectory=: systemd
              # recursively chowns RuntimeDirectory (including client.sock) back
              # to User:Group before spawning ExecStartPost whenever the dir's
              # group differs from Group=.
              "${coreUnit}-runtime".${assistant.runtimeDir}.d = {
                inherit (assistant) user;
                group = assistant.clientsGroup;
                mode = "0710";
              };
            }
            // optionalAttrs gw.enable {
              ${gatewayUnit}.${gwState}.d = {
                user = gw.user;
                group = gw.group;
                mode = "0700";
              };
            };

          systemd.timers =
            optionalAttrs (connectCfg.enable && connectCfg.renew.enable && connectDir != null)
              {
                "${prefix}-connect-renew" = {
                  description = "Periodically renew ${prefix} OAuth connections";
                  wantedBy = singleton "timers.target";
                  timerConfig = {
                    OnBootSec = "2min";
                    OnUnitActiveSec = connectCfg.renew.interval;
                    RandomizedDelaySec = "30s";
                    Persistent = true;
                  };
                };
              };

          systemd.services = {
            ${coreUnit} = {
              inherit (assistant) description;
              wantedBy = singleton "multi-user.target";
              restartIfChanged = false;
              unitConfig.ConditionFileIsExecutable = core;
              environment =
                optionalAttrs (assistant.core.path != null) { PATH = mkForce assistant.core.path; }
                // optionalAttrs (assistant.systemConfigDir != "/etc/libri-core") {
                  LIBRI_SYSTEM_CONFIG_DIR = assistant.systemConfigDir;
                }
                // optionalAttrs (assistant.configDir != null) {
                  LIBRI_CONFIG_DIR = assistant.configDir;
                }
                // assistant.core.extraEnv;
              serviceConfig = {
                User = assistant.user;
                Group = assistant.group;
                WorkingDirectory = assistant.home;
                SupplementaryGroups =
                  assistant.core.supplementaryGroups
                  ++ optionals yeomanImageCfg.enable (singleton "yeoman-image")
                  ++ singleton assistant.clientsGroup;
                StateDirectory = stateDirRel;
                StateDirectoryMode = "0700";
                # Keep the holders in this cgroup and stop only the daemon when enabled.
                KillMode = if assistant.core.keepHoldersAcrossRestart then "process" else "control-group";
                ExecStart = startCore;
                ExecStartPost = "${getExe pkgs.curl} --fail --silent --output /dev/null --retry 12 --retry-all-errors --retry-delay 1 --max-time 1 --unix-socket ${assistant.socketPath} http://localhost/v1/host";
                Type = "exec";
                TimeoutStartSec = 20;
                Restart = "always";
                RestartSec = 10;
                LimitCORE = 0;
              }
              // optionalAttrs (loadCredentials != [ ]) { LoadCredential = loadCredentials; }
              // coreExtraServiceConfig;
            };

            "${prefix}-ready" = {
              description =
                if prefix == "libri" then
                  "Proves Bridge's Stage 2 Libri core, gateway and hippo2 answer"
                else
                  "Proves ${name}'s Stage 2 Libri core, gateway and hippo2 answer";
              wantedBy = singleton "multi-user.target";
              after =
                singleton "${coreUnit}.service"
                ++ optionals (assistant.hippo2Unit != null) (singleton assistant.hippo2Unit)
                ++ optionals gw.enable (
                  singleton "${gatewayUnit}.service" ++ map (n: "${prefix}-addon-${n}.service") servedAddons
                )
                ++ optionals a2aServe (singleton "${prefix}-addon-a2a.service");
              restartTriggers =
                singleton config.systemd.units."${coreUnit}.service".unit
                ++ optionals (assistant.hippo2Unit != null) (
                  singleton config.systemd.units.${assistant.hippo2Unit}.unit
                )
                ++ optionals gw.enable (
                  singleton config.systemd.units."${gatewayUnit}.service".unit
                  ++ map (n: config.systemd.units."${prefix}-addon-${n}.service".unit) servedAddons
                )
                ++ optionals a2aServe (singleton config.systemd.units."${prefix}-addon-a2a.service".unit);
              path = [
                config.systemd.package
                pkgs.coreutils
                pkgs.curl
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                User = assistant.user;
                TimeoutStartSec = 180;
              };
              script = ''
                for _ in $(seq 85); do
                  curl -fsS -m3 --unix-socket ${assistant.socketPath} http://localhost/v1/host >/dev/null && break
                  sleep 1
                done
                curl -fsS -m3 --unix-socket ${assistant.socketPath} http://localhost/v1/host >/dev/null
                # Verify clientsGroup can traverse runtimeDir and connect to client.sock.
                [ "$(stat -c '%G %a' ${escapeShellArg assistant.runtimeDir})" = "${assistant.clientsGroup} 710" ]
                [ "$(stat -c '%G %a' ${escapeShellArg assistant.clientSocketPath})" = "${assistant.clientsGroup} 660" ]
                ${optionalString (gw.enable && servedAddons != [ ]) (
                  servedAddons
                  |> map (n: ''
                    for _ in $(seq 40); do
                      systemctl is-active --quiet ${prefix}-addon-${n}.service && break
                      sleep 1
                    done
                    systemctl is-active --quiet ${prefix}-addon-${n}.service
                  '')
                  |> concatStringsSep "\n"
                )}
                ${optionalString gw.enable ''
                  # Gateway state is 0700 to its own user, so check systemd's root-evaluated
                  # ConditionPathExists (admin.token + web assets) before probing the port.
                  if [ "$(systemctl show -P ConditionResult ${gatewayUnit}.service)" = "yes" ]; then
                    for _ in $(seq 40); do
                      curl -fsS -m3 http://127.0.0.1:${toString gw.port}/ >/dev/null && break
                      sleep 1
                    done
                    curl -fsS -m3 http://127.0.0.1:${toString gw.port}/ >/dev/null
                  fi
                ''}
                ${optionalString a2aServe ''
                  if [ -s ${a2aCfg.tokenFile} ] && [ -s ${a2aCfg.peersFile} ]; then
                    for _ in $(seq 40); do
                      systemctl is-active --quiet ${prefix}-addon-a2a.service && break
                      sleep 1
                    done
                    systemctl is-active --quiet ${prefix}-addon-a2a.service
                  fi
                ''}
                ${optionalString (assistant.hippo2Unit != null) ''
                  for _ in $(seq 40); do
                    systemctl is-active --quiet ${assistant.hippo2Unit} && break
                    sleep 1
                  done
                  systemctl is-active --quiet ${assistant.hippo2Unit}
                ''}
              '';
            };
          }
          // optionalAttrs gw.enable (
            addonUnits
            // {
              ${gatewayUnit} = {
                description =
                  if prefix == "libri" then
                    "Libri gateway: the core's /v1 for paired devices and the web view"
                  else
                    "Libri gateway for ${name}: /v1 for paired devices and the web view";
                wantedBy = singleton "multi-user.target";
                after =
                  singleton "${coreUnit}.service"
                  ++ map (addonName: "${prefix}-addon-${addonName}.service") servedAddons;
                wants =
                  singleton "${coreUnit}.service"
                  ++ map (addonName: "${prefix}-addon-${addonName}.service") servedAddons;
                unitConfig = {
                  ConditionFileIsExecutable = "${seat.libriBuild}/bin/libri-gateway";
                  ConditionPathExists = [
                    gwToken
                    "${gatewayWeb}/index.html"
                  ];
                };
                # Passing LIBRI_GATEWAY_ASSISTANT_NAME via environment (rather
                # than --assistant-name on ExecStart) keeps switcharoo safe if
                # the live libri-gateway binary predates --assistant-name.
                environment =
                  gatewayEnvironment
                  // optionalAttrs (gw.assistantName != null) {
                    LIBRI_GATEWAY_ASSISTANT_NAME = gw.assistantName;
                  }
                  // optionalAttrs (gw.uiMode == "simple") {
                    LIBRI_GATEWAY_UI_MODE = "simple";
                  };
                serviceConfig = lib.ship.hardened.tenant // {
                  User = gw.user;
                  Group = gw.group;
                  SupplementaryGroups = singleton assistant.clientsGroup;
                  # The proxy's SO_PEERCRED must carry nginx's real UID for
                  # --proxy-uid to match.
                  PrivateUsers = false;
                  StateDirectory = "${prefix}-gateway";
                  StateDirectoryMode = "0700";
                  RuntimeDirectory = "${prefix}-gateway";
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
                    "tcp:${toString gw.port}"
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
            "${prefix}-addon-a2a" = {
              description =
                if prefix == "libri" then
                  "Libri's inbound A2A peer receiver"
                else
                  "${name}'s inbound A2A peer receiver";
              wantedBy = singleton "multi-user.target";
              after = singleton "${coreUnit}.service";
              wants = singleton "${coreUnit}.service";
              unitConfig = {
                ConditionFileIsExecutable = addonBinary "a2a";
                ConditionPathExists = [
                  a2aCfg.peersFile
                  a2aCfg.tokenFile
                ];
              };
              serviceConfig = lib.ship.hardened.tenant // {
                User = assistant.user;
                Group = assistant.group;
                SupplementaryGroups = singleton assistant.clientsGroup;
                PrivateUsers = false;
                ExecStart = escapeShellArgs (
                  [
                    (addonBinary "a2a")
                    "serve"
                    "--listen"
                    a2aListen
                    "--peers-file"
                    a2aCfg.peersFile
                    "--core-socket"
                    assistant.clientSocketPath
                    "--core-token-file"
                    a2aCfg.tokenFile
                  ]
                  ++ optionals (a2aCfg.session != null) [
                    "--session"
                    a2aCfg.session
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
          }
          // optionalAttrs (connectCfg.enable && connectCfg.renew.enable && connectDir != null) {
            "${prefix}-connect-renew" = {
              description = "Renew ${prefix} OAuth connections";
              unitConfig = {
                ConditionFileIsExecutable = addonBinary "connect";
                ConditionPathExists = connectDir;
              };
              environment = addonEnvironment "connect";
              serviceConfig =
                lib.ship.hardened.tenant
                // fence
                // {
                  Type = "oneshot";
                  User = assistant.user;
                  Group = assistant.group;
                  RestrictAddressFamilies = [
                    "AF_UNIX"
                    "AF_INET"
                    "AF_INET6"
                  ];
                  ReadWritePaths = singleton connectDir;
                  ExecStart = escapeShellArgs [
                    (addonBinary "connect")
                    "renew"
                  ];
                  TimeoutStartSec = 60;
                };
            };
          }
          // optionalAttrs assistant.bootstrap.enable (
            let
              bs = assistant.bootstrap;
              ms = bs.mainSession;
              runuser = getExe' pkgs.util-linux "runuser";
              curl = getExe pkgs.curl;
              jq = getExe pkgs.jq;
              basename = getExe' pkgs.coreutils "basename";
              chmod = getExe' pkgs.coreutils "chmod";
              chown = getExe' pkgs.coreutils "chown";
              dirname = getExe' pkgs.coreutils "dirname";
              install = getExe' pkgs.coreutils "install";
              mktemp = getExe' pkgs.coreutils "mktemp";
              mv = getExe' pkgs.coreutils "mv";
              rm = getExe' pkgs.coreutils "rm";
              seq = getExe' pkgs.coreutils "seq";
              sleep = getExe' pkgs.coreutils "sleep";
            in
            {
              "${prefix}-bootstrap" = {
                description = "Bootstrap credentials and main session for ${name}";
                wantedBy = singleton "multi-user.target";
                after = singleton "${coreUnit}.service";
                wants = singleton "${coreUnit}.service";
                before =
                  optionals gw.enable (singleton "${gatewayUnit}.service")
                  ++ optionals a2aServe (singleton "${prefix}-addon-a2a.service")
                  ++ singleton "${prefix}-ready.service"
                  ++ optionals (assistant.hippo2Unit != null) (singleton assistant.hippo2Unit);
                unitConfig.ConditionFileIsExecutable = core;
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  set -euo pipefail

                  run_core() {
                    ${runuser} -u ${escapeShellArg assistant.user} -- \
                      ${core} \
                      --runtime-dir ${escapeShellArg assistant.runtimeDir} \
                      --data-dir ${escapeShellArg assistant.dataDir} \
                      "$@"
                  }

                  mint_token() {
                    local cred_name=$1 scope=$2 reach=$3 path=$4 owner=$5
                    if [ -s "$path" ]; then
                      return 0
                    fi
                    local dir tmp token
                    dir=$(${dirname} "$path")
                    if [ ! -d "$dir" ]; then
                      ${install} -d -m 0700 -o "''${owner%%:*}" -g "''${owner#*:}" "$dir"
                    fi
                    run_core credential revoke "$cred_name" >/dev/null 2>&1 || true
                    token=$(run_core --json credential add "$cred_name" --scope "$scope" --reach "$reach" | ${jq} -er .token)
                    tmp=$(${mktemp} "$dir/.$(${basename} "$path").XXXXXX")
                    if ! (
                      umask 077
                      printf '%s\n' "$token" > "$tmp"
                      ${chown} "$owner" "$tmp"
                      ${chmod} 0600 "$tmp"
                      ${mv} -f "$tmp" "$path"
                    ); then
                      ${rm} -f "$tmp"
                      return 1
                    fi
                  }

                  for _ in $(${seq} 30); do
                    if ${runuser} -u ${escapeShellArg assistant.user} -- \
                      ${curl} -fsS -m2 --unix-socket ${escapeShellArg assistant.socketPath} http://localhost/v1/host >/dev/null 2>&1; then
                      break
                    fi
                    ${sleep} 1
                  done
                  ${runuser} -u ${escapeShellArg assistant.user} -- \
                    ${curl} -fsS -m2 --unix-socket ${escapeShellArg assistant.socketPath} http://localhost/v1/host >/dev/null

                  ${optionalString gw.enable ''
                    mint_token gateway admin,read,operate,approve all ${escapeShellArg gwToken} ${escapeShellArg "${gw.user}:${gw.group}"}
                  ''}
                  ${optionalString a2aServe ''
                    mint_token a2a read,operate all ${escapeShellArg a2aCfg.tokenFile} ${escapeShellArg "${assistant.user}:${assistant.group}"}
                  ''}
                  ${optionalString (bs.hippo2TokenFile != null) ''
                    mint_token hippo2 read all ${escapeShellArg bs.hippo2TokenFile} ${escapeShellArg bs.hippo2Owner}
                  ''}
                  ${optionalString (ms != null) ''
                    sessions=$(run_core --json session list)
                    if ! printf '%s\n' "$sessions" | ${jq} -se 'any(.[]; .state != "closed" and (.labels.role // null) == "main")' >/dev/null; then
                      run_core session start \
                        --harness ${escapeShellArg ms.harness} \
                        --cwd ${escapeShellArg ms.cwd} \
                        --mode ${escapeShellArg ms.mode} \
                        --label role=main \
                        --label title=Main >/dev/null
                    fi
                  ''}
                '';
              };
            }
          );
        };

      # Cross-assistant isolation assertions: no two enabled assistants share a
      # unit prefix, runtime/state/config directory, gateway port, or A2A port.
      assistantNames = attrNames enabledAssistants;
      assistantPairs = concatMap (
        a: map (b: { inherit a b; }) (filter (b: a < b) assistantNames)
      ) assistantNames;
      pairAssertions = concatMap (
        { a, b }:
        let
          x = enabledAssistants.${a};
          y = enabledAssistants.${b};
        in
        [
          {
            assertion = x.unitPrefix != y.unitPrefix;
            message = "libri.assistants: ${a} and ${b} share unitPrefix ${x.unitPrefix}.";
          }
          {
            assertion = x.dataDir != y.dataDir;
            message = "libri.assistants: ${a} and ${b} share dataDir ${x.dataDir}.";
          }
          {
            assertion = x.runtimeDir != y.runtimeDir;
            message = "libri.assistants: ${a} and ${b} share runtimeDir ${x.runtimeDir}.";
          }
          {
            assertion = x.systemConfigDir != y.systemConfigDir;
            message = "libri.assistants: ${a} and ${b} share systemConfigDir ${x.systemConfigDir}.";
          }
          {
            assertion = !(x.gateway.enable && y.gateway.enable && x.gateway.port == y.gateway.port);
            message = "libri.assistants: ${a} and ${b} share gateway port ${toString x.gateway.port}.";
          }
          {
            assertion = !(x.a2a.enable && y.a2a.enable && x.a2a.port != null && x.a2a.port == y.a2a.port);
            message = "libri.assistants: ${a} and ${b} share a2a port ${toString x.a2a.port}.";
          }
        ]
      ) assistantPairs;

      # Aggregated Stage 2 deployment targets for deploy_libri.sh and polkit.
      deployAddons =
        (
          enabledAssistants
          |> attrValues
          |> concatMap (
            assistant:
            (assistant.addons |> filterAttrs (n: a: elem n stdAddonNames && a.enable) |> attrNames)
            ++ optionals assistant.addons.connect.enable (singleton "connect")
          )
        )
        ++ config.libri.deploy.extraAddons
        |> unique
        |> sort (a: b: a < b);

      deployServedAddons =
        enabledAssistants
        |> attrValues
        |> concatMap (
          assistant:
          let
            prefix = assistant.unitPrefix;
            served = servedAddonNames |> filter (n: assistant.addons.${n}.enable);
          in
          optionals assistant.gateway.enable (map (n: "${prefix}-addon-${n}:${n}") served)
          ++ optionals assistant.a2a.enable (singleton "${prefix}-addon-a2a:a2a")
        );

      deployCores = enabledAssistants |> attrValues |> map (assistant: "${assistant.unitPrefix}-core");

      deployGateways =
        enabledAssistants
        |> attrValues
        |> filter (assistant: assistant.gateway.enable)
        |> map (assistant: "${assistant.unitPrefix}-gateway:${toString assistant.gateway.port}");

      stage2ManagedUnits =
        enabledAssistants
        |> attrValues
        |> concatMap (
          assistant:
          let
            prefix = assistant.unitPrefix;
            served = servedAddonNames |> filter (n: assistant.addons.${n}.enable);
          in
          singleton "${prefix}-core.service"
          ++ optionals assistant.gateway.enable (
            singleton "${prefix}-gateway.service" ++ map (n: "${prefix}-addon-${n}.service") served
          )
          ++ optionals assistant.a2a.enable (singleton "${prefix}-addon-a2a.service")
        );

      # HOUSEHOLD IMAGE GENERATION

      image = pkgs.writers.writePython3Bin "yeoman-image-mcp" {
        libraries = singleton pkgs.python3Packages.mcp;
        flakeIgnore = singleton "E501";
      } (readFile ./assistant-image.py);

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
    in
    {
      options.libri = {
        assistants = mkOption {
          type = types.attrsOf (types.submodule assistantModule);
          default = { };
          description = "Independent Stage 2 Libri assistants running on this host.";
        };

        deploy.extraAddons = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Additional flake add-on names built and linked by `deploy_libri.sh` even when no assistant currently enables them.";
        };
      };

      config =
        let
          builtAssistants = enabledAssistants |> mapAttrsToList mkAssistant;
        in
        {
          assertions = pairAssertions ++ concatMap (a: a.assertions) builtAssistants;

          users.users = mkMerge (
            (builtAssistants |> map (a: a.users.users))
            ++ singleton {
              yeoman-image = {
                isSystemUser = true;
                group = "yeoman-image";
                home = "/var/lib/yeoman-image";
              };
            }
          );

          users.groups = mkMerge (
            (builtAssistants |> map (a: a.users.groups))
            ++ singleton {
              yeoman-image = { };
            }
          );

          environment.etc = mkMerge (builtAssistants |> map (a: a.environment.etc));
          environment.systemPackages = concatMap (a: a.environment.systemPackages) builtAssistants;
          environment.sessionVariables = mkMerge (builtAssistants |> map (a: a.environment.sessionVariables));

          shipProxy.routes = mkMerge (builtAssistants |> map (a: a.shipProxy.routes));

          systemd.tmpfiles.settings = mkMerge (
            (builtAssistants |> map (a: a.systemd.tmpfiles.settings))
            ++ singleton {
              yeoman-builds = {
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
            }
          );

          security.polkit.extraConfig = ''
            polkit.addRule(function (action, subject) {
              if (action.id == "org.freedesktop.systemd1.manage-units" &&
                  [${
                    concatMapStringsSep ", " (unit: ''"${unit}"'') stage2ManagedUnits
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

          systemd.timers = mkMerge (builtAssistants |> map (a: a.systemd.timers));

          systemd.services = mkMerge (
            (builtAssistants |> map (a: a.systemd.services))
            ++ singleton {
              libri-deploy.environment = {
                DEPLOY_LIBRI_CORES = concatStringsSep " " deployCores;
                DEPLOY_LIBRI_GATEWAYS = concatStringsSep " " deployGateways;
                DEPLOY_LIBRI_ADDONS = concatStringsSep " " deployAddons;
                DEPLOY_LIBRI_SERVED_ADDONS = concatStringsSep " " deployServedAddons;
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
                    BindReadOnlyPaths = singleton "${pkgs.emptyDirectory}:/etc/codex";
                  };
              };
            }
          );
        };
    };
}
