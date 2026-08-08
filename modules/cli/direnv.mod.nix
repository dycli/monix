# direnv with nix-direnv; shell hooks come from home-manager's
# enable*Integration defaults.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.direnv;
  flake.homeModules.direnv = {
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
  };
}
