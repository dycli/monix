# OpenCode's provider credentials on every host with an OpenCode client:
# one key for Zen and Go, one each for DeepSeek and abliteration.ai.
# lib/opencode.nix points the config at the decrypted files, so no key
# enters the Nix store.
{ self, ... }:
{
  flake.nixosModules.dev = self.nixosModules.opencode-auth;

  flake.nixosModules.opencode-auth =
    { config, lib, ... }:
    {
      # Readers of the key: the primary user here, the seat in its module.
      users.groups.opencode-auth = { };
      users.users.${config.primaryUser}.extraGroups = lib.lists.singleton "opencode-auth";

      secrets = lib.attrsets.genAttrs [ "opencode-key" "deepseek-key" "abliteration-key" ] (name: {
        file = ../../secrets/${name}.age;
        group = "opencode-auth";
        mode = "0440";
      });
    };
}
