# A work-Discord bot (./bot.py), self-contained in this folder: removing
# it means deleting these paths plus the enable and secret lines in the
# host.
#
# Slash commands for staff requests, checked off with inline per-row
# buttons. Rows are never deleted; check-off and clear are timestamps.
# The wholesale command set is unregistered, though old message buttons
# still work against the retained orders schema.
#
# Egress is the Discord API plus loopback for the resolver. The only
# credential is the bot token, read from an agenix env file. State is
# SQLite in /var/lib/curtisbot/bot.db.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.curtisbot;
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
      networkFences = lib.ship.fences;

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
          }
          // lib.optionalAttrs (cfg.guildId != null) {
            DISCORD_GUILD_ID = cfg.guildId;
          }
          // lib.optionalAttrs (cfg.testGuildId != null) {
            DISCORD_TEST_GUILD_ID = cfg.testGuildId;
          };
          serviceConfig = (lib.ship.hardened).tenant // {
            ExecStart = "${python}/bin/python ${./bot.py}";
            EnvironmentFile = cfg.credentialsEnvFile;
            Restart = "always";
            RestartSec = 10;

            User = "curtisbot";
            Group = "curtisbot";
            StateDirectory = "curtisbot";
            StateDirectoryMode = "0700";

            # Internet and loopback only.
            IPAddressAllow = networkFences.loopback;
            IPAddressDeny = networkFences.internetOnlyDeny;
          };
        };
      };
    };
}
