# Home Manager plumbing and the primary user's identity. Home aspects
# arrive through home-manager.sharedModules: every bundle a host imports
# carries its home aspects for all managed users (see
# options/flake-outputs.mod.nix).
{ self, inputs, ... }:
{
  flake.nixosModules.default = self.nixosModules.home-manager;
  flake.nixosModules.home-manager =
    { config, lib, ... }:
    let
      inherit (lib.lists) singleton;
    in
    {
      imports = singleton inputs.home-manager.nixosModules.home-manager;

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.backupFileExtension = "hm-bak";

      home-manager.users.${config.primaryUser} = {
        home.username = config.primaryUser;
        home.homeDirectory = "/home/${config.primaryUser}";
        home.stateVersion = config.system.stateVersion;
      };
    };
}
