{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.host;
  flake.nixosModules.host =
    { lib, ... }:
    let
      inherit (lib.options) mkOption;
      inherit (lib.types)
        bool
        ints
        listOf
        str
        ;
    in
    {
      options.primaryUser = mkOption {
        type = str;
        description = "Login name of the primary, human, admin user of the host.";
      };

      options.kestrel.allowSleep = mkOption {
        type = bool;
        default = true;
        description = "Whether Kestrel may suspend or hibernate this host.";
      };

      options.kestrel.idle = {
        lockEnabled = mkOption {
          type = bool;
          default = false;
          description = "Whether a fresh Kestrel profile locks after inactivity.";
        };
        lockMinutes = mkOption {
          type = ints.between 1 60;
          default = 5;
          description = "Default inactivity period before Kestrel locks.";
        };
        displayOffEnabled = mkOption {
          type = bool;
          default = false;
          description = "Whether a fresh Kestrel profile powers displays off after inactivity.";
        };
        displayOffMinutes = mkOption {
          type = ints.between 1 60;
          default = 7;
          description = "Default inactivity period before Kestrel powers displays off.";
        };
      };

      options.unfreePackages = mkOption {
        type = listOf str;
        default = [ ];
        description = ''
          Names (per lib.getName) of unfree packages the host may evaluate.
          Each module that installs an unfree package contributes its name
          here, next to the package itself; nix.mod.nix turns the merged
          list into the allowUnfreePredicate. There is no blanket
          allowUnfree — naming a package is the conscious act.
        '';
      };
    };
}
