# Steam additions for any host that enables it.
{ self, ... }:
{
  flake.nixosModules.desktop = self.nixosModules.steam;
  flake.nixosModules.steam =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      config = lib.mkIf config.programs.steam.enable {
        programs.steam.extraCompatPackages = [ pkgs.proton-ge-bin ];
        unfreePackages = [
          "steam"
          "steam-unwrapped"
        ];
      };
    };
}
