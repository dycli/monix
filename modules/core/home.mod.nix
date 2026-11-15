# Home Manager plumbing and the primary user's identity. Every bundle a host
# imports carries its home aspects to the primary user; any other managed
# user imports the home bundles it needs by name (see
# options/flake-outputs.mod.nix). Home Manager takes each user's name and home
# directory from `users.users`.
{ self, inputs, ... }:
{
  flake.commonModules.default = self.commonModules.home-manager;
  flake.commonModules.home-manager = {
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.backupFileExtension = "hm-bak";
  };

  flake.nixosModules.default = self.nixosModules.home-manager-linux;
  flake.nixosModules.home-manager-linux =
    { config, lib, ... }:
    {
      imports = lib.lists.singleton inputs.home-manager.nixosModules.home-manager;

      home-manager.users.${config.primaryUser}.home.stateVersion = config.system.stateVersion;
    };

  # nix-darwin's stateVersion is an integer, not a release, so each Darwin
  # host sets its primary user's home.stateVersion itself.
  flake.darwinModules.default = self.darwinModules.home-manager-darwin;
  flake.darwinModules.home-manager-darwin =
    { lib, ... }:
    {
      imports = lib.lists.singleton inputs.home-manager.darwinModules.home-manager;
    };
}
