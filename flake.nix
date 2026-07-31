{
  description = "NixOS configuration (Dendritic, single-repo, modular)";

  # Modules use |>, gated behind an experimental feature. The hosts carry
  # it in nix.settings (nix.mod.nix); this covers other evaluators that
  # pass --accept-flake-config. flake.nix itself stays pipe-free so a
  # stock parser can always read at least this file.
  nixConfig.extra-experimental-features = [ "pipe-operators" ];

  inputs.nixpkgs = {
    url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  inputs.nixos-hardware = {
    url = "github:NixOS/nixos-hardware/master";
  };

  inputs.flake-parts = {
    url = "github:hercules-ci/flake-parts";
    inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  inputs.home-manager = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.disko = {
    url = "github:nix-community/disko";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.agenix = {
    url = "github:ryantm/agenix";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.home-manager.follows = "home-manager";
    inputs.darwin.follows = "";
  };

  # master: stable predates the Hyprland 0.55 Lua command socket fixes
  # that DMS workspace clicking needs.
  inputs.dank-material-shell = {
    url = "github:AvengeMedia/DankMaterialShell";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # The greeter lives in its own repo and nixpkgs ships no module for it.
  inputs.dank-greeter = {
    url = "github:AvengeMedia/dank-greeter";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.nix4nvchad = {
    url = "github:nix-community/nix4nvchad";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Hypervisor-backed guests for the agent fleet.
  inputs.microvm = {
    url = "github:microvm-nix/microvm.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Minecraft servers as a NixOS service. Deliberately does not follow our
  # nixpkgs: its server packages are built and cached against its own pin,
  # and following ours would forfeit those cache hits.
  inputs.nix-minecraft = {
    url = "github:Infinidoge/nix-minecraft";
  };

  outputs =
    inputs:
    let
      # The ship's lib (nixpkgs.lib + lib.ship), threaded into flake-parts
      # here and into every nixosSystem by ship.host.
      lib = import ./lib inputs.nixpkgs.lib;

      inherit (lib.attrsets) filterAttrs mapAttrs' nameValuePair;
      inherit (lib.strings) hasSuffix removeSuffix;

      # flake-parts' module set, read the way its own flake.nix builds it;
      # required arguments of its lib.nix entry point.
      flakePartsModules =
        directory:
        mapAttrs' (name: _: nameValuePair (removeSuffix ".nix" name) "${directory}/${name}") (
          filterAttrs (name: _: hasSuffix ".nix" name) (builtins.readDir directory)
        );
    in
    (import "${inputs.flake-parts}/lib.nix" {
      inherit lib;
      builtinModules = flakePartsModules "${inputs.flake-parts}/modules";
      extraModules = flakePartsModules "${inputs.flake-parts}/extras";
    }).mkFlake
      {
        inherit inputs;
      }
      (
        { lib, ... }:
        {
          # Every *.mod.nix in the tree is a flake-parts module, imported
          # automatically; there is no central list.
          imports = lib.lists.filter (lib.strings.hasSuffix ".mod.nix") (
            lib.filesystem.listFilesRecursive ./.
          );
        }
      );
}
