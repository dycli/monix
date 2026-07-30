# git + gh.
{
  flake.homeModules.git =
    { ... }:
    {
      programs.git = {
        enable = true;

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
