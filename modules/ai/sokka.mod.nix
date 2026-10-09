# Sokka, the household assistant (sokka/): one endless Matrix chat with no
# sessions. Each message from an allowed user becomes one fresh model call
# over Sokka's prompt, its whole memory and the message; message and answer
# both go into Sokka's own hippo store, so the next call remembers them.
#
# Two units under one static user: the bot, and the hippo service that is
# the store's only writer. Model calls run the claude CLI on the fleet's
# subscription token, without built-in tools or settings; their only tools
# are Parallel's keyless web search and fetch, over MCP.
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
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatStringsSep;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.sokka;
      state = "/var/lib/sokka";

      sokka = lib.ship.rustTool pkgs { src = ./sokka; };
      hippo = lib.ship.rustTool pkgs { src = ./seat/hippo; };

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

      mcp = (pkgs.formats.json { }).generate "sokka-mcp.json" {
        mcpServers.parallel = {
          type = "http";
          url = "https://search.parallel.ai/mcp";
        };
      };

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

      sandbox = lib.ship.hardened.tenant // {
        User = "sokka";
        Group = "sokka";
        StateDirectory = "sokka";
        StateDirectoryMode = "0700";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };

      # The homeserver and resolver on loopback, and the internet for the
      # model; not the tailnet, the LAN or the seat's loopback address.
      fence = {
        IPAddressAllow = fences.loopback;
        IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
      };

      # Each claude call writes its state under HOME.
      claudeUnit = {
        LoadCredential = "claude-token:${cfg.claudeTokenFile}";
        BindReadOnlyPaths = singleton "${claudeEtc}:/etc/claude-code";
      };

      env = {
        HOME = state;
        HIPPO_DIR = "${state}/hippo";
      };
    in
    {
      options.sokka = {
        credentialsEnvFile = mkOption {
          type = types.str;
          description = ''
            agenix env file with MATRIX_USER=@sokka:server and
            MATRIX_PASSWORD=..., Sokka's own Matrix account, registered on
            first start.
          '';
        };

        registrationEnvFile = mkOption {
          type = types.str;
          description = ''
            agenix env file with TUWUNEL_REGISTRATION_TOKEN=..., used only by
            the account-registration oneshot.
          '';
        };

        claudeTokenFile = mkOption {
          type = types.str;
          description = "File holding a Claude Code OAuth token.";
        };

        users = mkOption {
          type = types.listOf types.str;
          example = singleton "@alice:chat.example.com";
          description = ''
            Who Sokka talks with: it joins rooms they invite it to and
            answers only them.
          '';
        };

        model = mkOption {
          type = types.str;
          default = "opus";
          description = "Claude model that answers.";
        };

        viewBytes = mkOption {
          type = types.ints.positive;
          default = 24000;
          description = "Budget of Sokka's memory view, sent with every call.";
        };
      };

      config = {
        users.users.sokka = {
          isSystemUser = true;
          group = "sokka";
          home = state;
        };
        users.groups.sokka = { };

        systemd.services.sokka-register = {
          description = "Sokka Matrix account bootstrap";
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
                cfg.credentialsEnvFile
                cfg.registrationEnvFile
              ];
            };
        };

        systemd.services.sokka-hippo = {
          description = "Sokka's memory";
          wantedBy = singleton "multi-user.target";
          environment = env // {
            HIPPO_AGENT = "Sokka";
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
                "sokka"
                "sokka/hippo"
              ];
              ExecStart = "${getExe hippo} serve --no-follow";
              Restart = "always";
              RestartSec = 5;
            };
        };

        systemd.services.sokka = {
          description = "Sokka, the household assistant";
          wantedBy = singleton "multi-user.target";
          wants = [
            "tuwunel.service"
            "sokka-register.service"
            "sokka-hippo.service"
          ];
          after = [
            "tuwunel.service"
            "sokka-register.service"
            "sokka-hippo.service"
          ];
          environment = env // {
            SOKKA_HOMESERVER = "http://127.0.0.1:${toString config.matrix.port}";
            SOKKA_USERS = concatStringsSep "," cfg.users;
            SOKKA_BACKEND = "claude";
            SOKKA_CLAUDE = getExe claude;
            SOKKA_MODEL = cfg.model;
            SOKKA_MCP = toString mcp;
          };
          serviceConfig =
            sandbox
            // fence
            // claudeUnit
            // {
              ExecStart = getExe sokka;
              EnvironmentFile = cfg.credentialsEnvFile;
              Restart = "always";
              RestartSec = 10;
            };
        };
      };
    };
}
