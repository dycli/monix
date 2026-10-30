# nixpkgs.lib extended with the ship's library as `lib.ship`. `ship.host`
# builds systems with `final.nixosSystem`, which passes `lib = final` through
# the lib.extend fixpoint, so flake, NixOS and Home Manager modules all reach
# `lib.ship.*` without relative lib/ imports.
inputs:
inputs.nixpkgs.lib.extend (
  final: prev: {
    ship = {
      browsers = import ./browsers.nix;
      computers = import ./computers.nix final;
      fences = import ./network-fences.nix;
      hardened = import ./hardened.nix final;
      topology = import ./topology.nix;
      guide = import ./guide.nix;
      keys = import ../keys.nix;
      opencode = import ./opencode.nix final;
      rustTool = import ./rust-tool.nix final inputs.crate2nix;
      hippoDoor = import ./hippo-door.nix final;
      # hippo as Libri's deploy last built it at `build`, with `env` set: the
      # repository that holds it isn't on GitHub, so this host's flake can't
      # fetch it.
      libriHippo =
        pkgs: build: env:
        pkgs.writeShellApplication {
          name = "hippo";
          text = final.concatStrings (
            final.mapAttrsToList (k: v: "export ${k}=\"\${${k}:-${v}}\"\n") env
          ) + "exec ${build}/bin/hippo \"$@\"\n";
        };

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
