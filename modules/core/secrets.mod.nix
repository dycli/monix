{ inputs, ... }:
{
  flake.nixosModules.secrets =
    { lib, ... }:
    let
      inherit (lib.modules) mkAliasOptionModule;
    in
    {
      imports = [
        inputs.agenix.nixosModules.age
        (mkAliasOptionModule [ "secrets" ] [ "age" "secrets" ])
      ];

      # Decrypt secrets using this host's SSH host key. The matching public key
      # must be present in keys.nix and secrets must be encrypted to it.
      age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
}
