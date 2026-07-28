# curtisbot aspect — Curtis, the work-Discord bot (see ./bot.py).
# Self-contained in this folder so it can be removed or moved wholesale —
# delete these two paths plus the enable/secret lines in hosts/fw0.
#
# Slash commands for staff requests (/request form, /requests), checked off
# via inline per-row buttons; checked rows stay struck-through until /clear.
# Rows are never deleted — check-off and clear are timestamps. The wholesale
# command set is PARKED (unregistered; see bot.py) — old wholesale message
# buttons still work against the retained orders schema.
#
# Egress is internet-only (Discord gateway/API) plus loopback for the
# resolver; LAN/tailnet/fleet ranges stay denied. The only credential is the
# bot token, supplied as an agenix env file (DISCORD_TOKEN=...), read from
# the environment and never written to disk or logs.
#
# DATA. /var/lib/curtisbot/bot.db (orders + requests, SQLite).
{
  flake.nixosModules.curtisbot =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;

      cfg = config.curtisbot;
      networkFences = import ../../../lib/network-fences.nix;

      python = pkgs.python3.withPackages (ps: [ ps.discordpy ]);
    in
    {
      options.curtisbot = {
        enable = mkEnableOption "Curtis work-Discord orders/requests bot";

        credentialsEnvFile = mkOption {
          type = types.str;
          description = ''
            agenix env file with DISCORD_TOKEN=... — the bot token from the
            Discord developer portal.
          '';
        };

        guildId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Discord guild (server) id to sync slash commands to. Set it for
            instant command availability in that one server; null syncs
            globally, which Discord can take up to an hour to propagate.
          '';
        };

        testGuildId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Optional second guild for testing: commands sync there too,
            but its interactions hit a separate sandbox database
            (test.db) so experiments never touch the real data.
          '';
        };
      };

      config = mkIf cfg.enable {
        users.users.curtisbot = {
          isSystemUser = true;
          group = "curtisbot";
        };
        users.groups.curtisbot = { };

        systemd.services.curtisbot = {
          description = "Curtis work-Discord orders/requests bot";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          environment = {
            CURTISBOT_DB = "/var/lib/curtisbot/bot.db";
            CURTISBOT_TEST_DB = "/var/lib/curtisbot/test.db";
          } // lib.optionalAttrs (cfg.guildId != null) {
            DISCORD_GUILD_ID = cfg.guildId;
          } // lib.optionalAttrs (cfg.testGuildId != null) {
            DISCORD_TEST_GUILD_ID = cfg.testGuildId;
          };
          # Shared hardening preset (lib/hardened.nix) + unit identity.
          serviceConfig = (import ../../../lib/hardened.nix).tenant // {
            ExecStart = "${python}/bin/python ${./bot.py}";
            EnvironmentFile = cfg.credentialsEnvFile;
            Restart = "always";
            RestartSec = 10;

            User = "curtisbot";
            Group = "curtisbot";
            StateDirectory = "curtisbot";
            StateDirectoryMode = "0700";
            Slice = "services.slice";

            # Internet + loopback; LAN/tailnet/fleet stay denied.
            IPAddressAllow = [
              "127.0.0.0/8"
              "::1"
            ];
            IPAddressDeny = networkFences.internetOnlyDeny;
          };
        };
      };
    };
}
