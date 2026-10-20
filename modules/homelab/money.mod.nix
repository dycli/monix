# The household's money page at https://money.<domain> (tailnet only): ./money
# holds the Plaid keys and each bank login's access token, pulls accounts,
# transactions, holdings and card statements into finance.db every six hours
# (under /var/lib/money/<environment>), and serves the page: net worth,
# spending by category, holdings, and a Banks tab where we link a bank. Its own user is the wall: nothing
# else, Sokka included, can read the keys or the tokens. The `finance` group
# reads finance.db and nothing more; the `money` group may also change what
# the page shows (categories, budget lines, hand-kept accounts) through
# /run/money.sock, the same API without the page.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.money;
  flake.nixosModules.money =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.money;
      port = 8975;
      money = lib.ship.rustTool pkgs { src = ./money; };
    in
    {
      options.money = {
        keysFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            `KEY=value` lines: PLAID_CLIENT_ID, and PLAID_SANDBOX_SECRET or
            PLAID_SECRET for the environment in use; null = off.
          '';
        };
        environment = mkOption {
          type = types.enum [
            "sandbox"
            "production"
          ];
          default = "sandbox";
          description = "Plaid's fake banks, or real ones (each login takes a Trial slot for good).";
        };
      };

      config = mkIf (cfg.keysFile != null) {
        shipProxy.routes.money.port = port;

        users.users.money = {
          isSystemUser = true;
          group = "finance";
        };
        users.groups.finance = { };
        users.groups.money = { };

        # The service was called plaid until 2026-10; this carries its
        # databases over once, after the old unit stops and before the new
        # one starts. Remove it once Water has switched past the rename.
        system.activationScripts.money-state = {
          deps = singleton "users";
          text = ''
            if [ -d /var/lib/plaid ] && [ ! -e /var/lib/money ]; then
              mv /var/lib/plaid /var/lib/money
              chown -R money:finance /var/lib/money
            fi
          '';
        };

        systemd.sockets.money = {
          description = "The money page's API for the household assistants";
          wantedBy = singleton "sockets.target";
          socketConfig = {
            ListenStream = "/run/money.sock";
            SocketMode = "0660";
            SocketGroup = "money";
          };
        };

        systemd.services.money = {
          description = "The household's money page and bank link";
          wantedBy = singleton "multi-user.target";
          after = [
            "network-online.target"
            "money.socket"
          ];
          requires = singleton "money.socket";
          wants = singleton "network-online.target";
          environment = {
            MONEY_LISTEN = "127.0.0.1:${toString port}";
            MONEY_ENV = cfg.environment;
            MONEY_KEYS_FILE = "%d/keys";
            # Each environment keeps its own databases, so test banks never
            # mix with real ones.
            MONEY_STATE = "%S/money/${cfg.environment}";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            User = "money";
            Group = "finance";
            StateDirectory = "money";
            StateDirectoryMode = "0750";
            # Group-readable files; the vault folder is narrowed to the owner.
            UMask = "0027";
            ExecStart = getExe money;
            LoadCredential = singleton "keys:${cfg.keysFile}";
            Restart = "on-failure";
            SocketBindDeny = "any";
            SocketBindAllow = singleton "tcp:${toString port}";
            # Plaid on the internet and nginx on loopback; the LAN and tailnet stay shut.
            IPAddressAllow = fences.loopback;
            IPAddressDeny = fences.internetOnlyDeny;
          };
        };
      };
    };
}
