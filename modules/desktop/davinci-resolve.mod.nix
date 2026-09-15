# DaVinci Resolve is a workstation-only addition to the creative bundle.
{ self, ... }:
{
  flake.nixosModules.davinci-resolve =
    { lib, ... }:
    {
      unfreePackages = lib.lists.singleton "davinci-resolve";
    };

  flake.homeModules.davinci-resolve =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.davinci-resolve ];
    };
}
