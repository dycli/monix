# One OpenCode credential for Zen and Go on every host with an OpenCode
# client. lib/opencode.nix points the config at the decrypted file, so the
# key never enters the Nix store.
{ self, ... }:
{
  flake.nixosModules.dev = self.nixosModules.opencode-auth;

  flake.nixosModules.opencode-auth =
    { config, lib, ... }:
    {
      # Readers of the key: the primary user here, the seat in its module.
      users.groups.opencode-auth = { };
      users.users.${config.primaryUser}.extraGroups = lib.lists.singleton "opencode-auth";

      secrets.opencode-key = {
        file = ../../secrets/opencode-key.age;
        group = "opencode-auth";
        mode = "0440";
      };
    };
}
