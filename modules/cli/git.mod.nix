# git + gh.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.git;
  flake.homeModules.git =
    { pkgs, ... }:
    {
      programs.git = {
        enable = true;
        # Minimal build: the perl/python porcelain is dead weight fleet-wide.
        package = pkgs.gitMinimal;

        settings = {
          user.name = "Dylan Cleary";
          user.email = "dylan@dylanc.com";

          init.defaultBranch = "main";
          pull.rebase = true;

          # git refuses another user's repo without this, and honours it
          # only from a global config file, never via -c or the environment.
          safe.directory = "/home/bridge/ark/monix";
        };
      };

      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = true;
      };
    };
}
