{
  description = "NixOS configuration (Dendritic, single-repo, modular)";

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

  # master, not stable: stable predates the fixes for Hyprland 0.55's Lua
  # command socket needed for DMS workspace clicking.
  inputs.dank-material-shell = {
    url = "github:AvengeMedia/DankMaterialShell";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # The DMS greetd greeter moved out of DankMaterialShell into its own repo
  # (2026-07); nixpkgs still ships no DMS greeter module.
  inputs.dank-greeter = {
    url = "github:AvengeMedia/dank-greeter";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.nix4nvchad = {
    url = "github:nix-community/nix4nvchad";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # microvm.nix: hypervisor-backed guests for the agent fleet (see
  # modules/server/microvm-host.mod.nix, gated on agentFleet.enable).
  inputs.microvm = {
    url = "github:microvm-nix/microvm.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # nix-minecraft: declarative Fabric/vanilla/etc. Minecraft servers as a
  # NixOS service (see modules/server/minecraft.mod.nix, gated on
  # minecraft.enable). Does NOT follow our nixpkgs: its server packages are
  # built and cached against its own pinned nixpkgs, so leaving it pinned
  # avoids a mass rebuild and keeps the binary cache hits.
  inputs.nix-minecraft = {
    url = "github:Infinidoge/nix-minecraft";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake
      {
        inherit inputs;
      }
      (
        { lib, ... }:
        {
          # The Dendritic Pattern: every `*.mod.nix` file in the tree is a
          # flake-parts module and is imported automatically. There is no
          # central list of modules to maintain.
          imports = lib.lists.filter (lib.strings.hasSuffix ".mod.nix") (
            lib.filesystem.listFilesRecursive ./.
          );
        }
      );
}
