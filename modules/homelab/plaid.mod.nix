# The household's money page at https://money.<domain> (tailnet only): ./plaid
# holds the Plaid keys and each bank login's access token, pulls accounts,
# transactions, holdings and card statements into finance.db every six hours
# (under /var/lib/plaid/<environment>), and serves the page: net worth,
# spending by category, holdings, and a Banks tab where we link a bank. Its own user is the wall: nothing
# else, Sokka included, can read the keys or the tokens. The `finance` group
# reads finance.db and nothing more; the `money` group may also change what
# the page shows (categories, budget lines, hand-kept accounts) through
# /run/plaid.sock, the same API without the page.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.plaid;
  flake.nixosModules.plaid =
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

      cfg = config.plaid;
      port = 8975;
      plaid = lib.ship.rustTool pkgs { src = ./plaid; };
    in
    {
      options.plaid = {
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

        users.users.plaid = {
          isSystemUser = true;
          group = "finance";
        };
        users.groups.finance = { };
        users.groups.money = { };

        systemd.sockets.plaid = {
          description = "The money page's API for the household assistants";
          wantedBy = singleton "sockets.target";
          socketConfig = {
            ListenStream = "/run/plaid.sock";
            SocketMode = "0660";
            SocketGroup = "money";
          };
        };

        systemd.services.plaid = {
          description = "The household's bank link";
          wantedBy = singleton "multi-user.target";
          after = [
            "network-online.target"
            "plaid.socket"
          ];
          requires = singleton "plaid.socket";
          wants = singleton "network-online.target";
          environment = {
            PLAID_LISTEN = "127.0.0.1:${toString port}";
            PLAID_ENV = cfg.environment;
            PLAID_KEYS_FILE = "%d/keys";
            # Each environment keeps its own databases, so test banks never
            # mix with real ones.
            PLAID_STATE = "%S/plaid/${cfg.environment}";
          };
          serviceConfig = lib.ship.hardened.tenant // {
            User = "plaid";
            Group = "finance";
            StateDirectory = "plaid";
            StateDirectoryMode = "0750";
            # Group-readable files; the vault folder is narrowed to the owner.
            UMask = "0027";
            ExecStart = getExe plaid;
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
