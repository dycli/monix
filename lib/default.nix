# nixpkgs.lib extended with the ship's library as `lib.ship`. `ship.host`
# builds systems with `final.nixosSystem`, which passes `lib = final` through
# the lib.extend fixpoint, so flake, NixOS and Home Manager modules all reach
# `lib.ship.*` without relative lib/ imports.
nixpkgsLib:
nixpkgsLib.extend (
  final: prev: {
    ship = {
      fences = import ./network-fences.nix;
      hardened = import ./hardened.nix final;
      topology = import ./fleet-topology.nix;
      guide = import ./fleet-guide.nix;
      keys = import ../keys.nix;

      # `ship.host "name" module` is a flake-parts module defining
      # nixosConfigurations.name. Every host gets the `default` bundle.
      host =
        hostName: module:
        { inputs, ... }:
        {
          flake.nixosConfigurations.${hostName} = final.nixosSystem {
            modules = [
              inputs.self.nixosModules.default
              module
              { networking.hostName = hostName; }
            ];
          };
        };
    };
  }
)
