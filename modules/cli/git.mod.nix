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

          # The seat's clone is the repo of record on fw0 (switcharoo pulls
          # from it); git refuses another user's repo without this. Only in
          # a global config file — git ignores safe.directory via -c/env.
          safe.directory = "/home/bridge/ark/monix";

          # Credentials are handled by gh (below) — no plaintext
          # `credential.helper = store`.
        };
      };

      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = true;
      };
    };
}
