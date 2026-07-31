{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.users;
  flake.nixosModules.users =
    { config, ... }:
    {
      # Accounts are fully declarative: /etc/shadow is regenerated from the
      # config on every activation, so `passwd` does not stick — each host
      # declares its primary user's hashedPasswordFile from a secret.
      users.mutableUsers = false;

      # Hosts provide password policy and credentials for their primary user.
      users.users.${config.primaryUser} = {
        isNormalUser = true;
        description = config.primaryUser;

        extraGroups = [ "wheel" ];

        openssh.authorizedKeys.keys = self.keys-admin;
      };
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
