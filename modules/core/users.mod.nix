{ self, ... }:
{
  flake.nixosModules.users =
    {
      config,
      lib,
      ...
    }:
    let
      inherit (lib.lists) optionals;
    in
    {
      # Hosts provide password policy and credentials for their primary user.
      users.users.${config.primaryUser} = {
        isNormalUser = true;
        description = config.primaryUser;

        extraGroups = [
          "wheel"
        ]
        ++ optionals config.isDesktop [
          "networkmanager"
          "video"
          "audio"
          "input"
        ];

        openssh.authorizedKeys.keys = self.keys-admin;
      };
    };
}
