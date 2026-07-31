# nixpkgs.lib extended with the ship's library as `lib.ship`, threaded
# everywhere: flake.nix hands this to flake-parts, so flake-level modules
# (including hosts) see it, and `ship.host` builds systems with
# `final.nixosSystem` — nixpkgs passes `lib = final` through the
# lib.extend fixpoint, so NixOS and Home Manager modules see it too.
# Modules use `lib.ship.*` instead of relative lib/ imports, whose depth
# varies by file location and gets copied wrong.
nixpkgsLib:
nixpkgsLib.extend (
  final: prev: {
    ship = {
      fences = import ./network-fences.nix;
      hardened = import ./hardened.nix;
      topology = import ./fleet-topology.nix;
      guide = import ./fleet-guide.nix;

      # Host constructor: `ship.host "name" module` is a flake-parts
      # module defining nixosConfigurations.name. Every host imports the
      # `default` bundle; the host module adds its other bundles, hardware
      # and identity.
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
