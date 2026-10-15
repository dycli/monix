# CI: a GitHub Actions runner on Water for monix. GitHub only triggers it;
# the job is `nix flake check`, which also builds every host, so a green
# check means the deploy will build and its store paths are already here.
# The runner is ephemeral (fresh registration and work directory per job)
# and fenced to the internet. monix is public, so a fork's pull request
# could target this runner; the repository requires approval before any
# outside contributor's workflow runs, which keeps strangers' code off
# Water. Hosts without `ci.tokenFile` leave the runner off.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.ci;
  flake.nixosModules.ci =
    { config, lib, ... }:
    let
      inherit (lib) types;
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.ship) fences;

      cfg = config.ci;
    in
    {
      options.ci.tokenFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Fine-grained GitHub token for dycli/monix (Administration: read and
          write, to register the runner), raw; null leaves CI off.
        '';
      };

      config = mkIf (cfg.tokenFile != null) {
        services.github-runners.monix = {
          enable = true;
          url = "https://github.com/dycli/monix";
          inherit (cfg) tokenFile;
          ephemeral = true;
          replace = true;
          extraLabels = singleton "water";
          extraPackages = singleton config.nix.package;
          serviceOverrides = {
            # GitHub and caches only; the house stays out of reach.
            IPAddressDeny = fences.internetOnlyDeny;
          };
        };
      };
    };
}
