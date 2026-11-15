{ self, ... }:
{
  flake.commonModules.default = self.commonModules.users;
  flake.commonModules.users =
    { config, lib, ... }:
    {
      users.users.${config.primaryUser}.openssh.authorizedKeys.keys = lib.ship.keys.admin;
    };

  flake.nixosModules.default = self.nixosModules.users-linux;
  flake.nixosModules.users-linux =
    { config, lib, ... }:
    {
      # Accounts are fully declarative: /etc/shadow is regenerated from the
      # config on every activation, so `passwd` does not stick — each host
      # declares its primary user's hashedPasswordFile from a secret.
      users.mutableUsers = false;

      # Hosts provide password policy and credentials for their primary user.
      users.users.${config.primaryUser} = {
        isNormalUser = true;
        description = config.primaryUser;

        extraGroups = lib.lists.singleton "wheel";
      };
    };

  # A Darwin host keeps its accounts in macOS's own hands. nix-darwin creates,
  # changes or deletes only the users and groups named in knownUsers and
  # knownGroups; its Nix module names the hidden build accounts the Nix
  # installer made, and nothing else may join them, so the `users.users`
  # entry for the primary user only describes an existing account. A Mac may
  # be shared, and the other accounts must stay untouched.
  flake.darwinModules.default = self.darwinModules.users-darwin;
  flake.darwinModules.users-darwin =
    { config, lib, ... }:
    let
      inherit (lib.lists) all;
      inherit (lib.strings) hasPrefix;

      buildAccount = name: hasPrefix "_nixbld" name || hasPrefix "nixbld" name;
    in
    {
      # nix-darwin writes per-user settings (system.defaults, Homebrew) for
      # this one account.
      system.primaryUser = config.primaryUser;

      users.users.${config.primaryUser} = {
        home = "/Users/${config.primaryUser}";
        # Water's seat deploys a Darwin host over SSH as its primary user.
        openssh.authorizedKeys.keys = lib.lists.singleton lib.ship.keys.seat;
      };

      assertions = [
        {
          assertion = all buildAccount config.users.knownUsers && all buildAccount config.users.knownGroups;
          message = "users.knownUsers and users.knownGroups may name only Nix's build accounts: macOS owns the rest.";
        }
      ];
    };

  # Desktop session groups for the primary user.
  flake.nixosModules.desktop =
    { config, ... }:
    {
      users.users.${config.primaryUser}.extraGroups = [
        "networkmanager"
        "video"
        "audio"
        "input"
      ];
    };
}
