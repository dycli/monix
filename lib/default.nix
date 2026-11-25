# nixpkgs.lib extended with the ship's library as `lib.ship`. `ship.host`
# builds systems with `final.nixosSystem`, which passes `lib = final` through
# the lib.extend fixpoint, so flake, NixOS and Home Manager modules all reach
# `lib.ship.*` without relative lib/ imports.
inputs:
inputs.nixpkgs.lib.extend (
  final: prev: {
    ship = {
      computers = import ./computers.nix final;
      fences = import ./network-fences.nix;
      hardened = import ./hardened.nix final;
      topology = import ./topology.nix;
      tunnel = import ./tunnel.nix final;
      keys = import ../keys.nix;
      opencode = import ./opencode.nix final;
      rustTool = import ./rust-tool.nix final inputs.crate2nix;

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

      # `ship.darwinHost "name" module` is the macOS counterpart, defining
      # darwinConfigurations.name from the Darwin `default` bundle. darwinSystem
      # takes `lib` as given, so Darwin modules reach `lib.ship.*` too.
      darwinHost =
        hostName: module:
        { inputs, ... }:
        {
          flake.darwinConfigurations.${hostName} = inputs.nix-darwin.lib.darwinSystem {
            lib = final;
            modules = [
              inputs.self.darwinModules.default
              module
              { networking.hostName = hostName; }
            ];
          };
        };
    };
  }
)
