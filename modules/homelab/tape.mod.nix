# The market-data tape: Lantern's Rust recorder keeping Databento's CME order book
# (GLBX.MDP3, MBO, the front and next contract of each root) on the NAS as
# one Zstandard DBN file per UTC day and connection. `tape-pull` buys a
# slice of history into the same archive after showing its price. Nothing
# reads the tape yet; the charting client comes later. Water leaves
# `tape.keyFile` unset until the Databento subscription starts, so the
# recorder is built but not installed.
{ self, inputs, ... }:
{
  flake.nixosModules.lab = self.nixosModules.tape;
  flake.nixosModules.tape =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) types;
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep concatStringsSep;
      inherit (lib.ship) fences hardened;

      cfg = config.tape;
      dir = "/srv/storage/tape";

      tape = inputs.lantern.packages.${pkgs.stdenv.hostPlatform.system}.tape;

      # Continuous contracts, front and next, so a roll never drops a book.
      roots = [
        "ES"
        "MES"
        "NQ"
        "MNQ"
        "ZT"
        "ZF"
        "ZN"
        "TN"
        "ZB"
        "UB"
        "CL"
        "NG"
      ];
      symbols = concatMapStringsSep "," (root: "${root}.c.0,${root}.c.1") roots;

      environment = {
        TAPE_DIR = dir;
        TAPE_KEY_FILE = cfg.keyFile;
        TAPE_SYMBOLS = symbols;
      };

      pull = pkgs.writeShellApplication {
        name = "tape-pull";
        text = ''
          exec sudo -u tape env ${
            concatStringsSep " " (lib.attrsets.mapAttrsToList (n: v: "${n}=${v}") environment)
          } ${getExe tape} pull "$@"
        '';
      };
    in
    {
      options.tape.keyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Databento API key, raw; null leaves the recorder off.";
      };

      config = mkIf (cfg.keyFile != null) {
        users.users.tape = {
          isSystemUser = true;
          group = "tape";
        };
        users.groups.tape = { };

        systemd.tmpfiles.rules = singleton "d ${dir} 0750 tape tape -";

        systemd.services.tape = {
          description = "Record the CME order book from Databento";
          wantedBy = singleton "multi-user.target";
          wants = singleton "network-online.target";
          after = [
            "network-online.target"
            "srv-storage.mount"
          ];
          bindsTo = singleton "srv-storage.mount";
          unitConfig.RequiresMountsFor = dir;
          inherit environment;
          serviceConfig = hardened.tenant // {
            User = "tape";
            Group = "tape";
            ExecStart = "${getExe tape} record";
            ReadWritePaths = singleton dir;
            Restart = "always";
            RestartSec = 10;
            # Databento's gateways only; the house stays out of reach.
            IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
          };
        };

        environment.systemPackages = [
          tape
          pull
        ];
      };
    };
}
