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
        };
      };

      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = true;
      };
    };
}
