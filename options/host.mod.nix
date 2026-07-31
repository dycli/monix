{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.host;
  flake.nixosModules.host =
    { lib, ... }:
    let
      inherit (lib.options) mkOption;
      inherit (lib.types) listOf str;
    in
    {
      options.primaryUser = mkOption {
        type = str;
        description = "Login name of the primary, human, admin user of the host.";
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
