# hippo on its own: the same build the ship gives it inside monix
# (lib/rust-tool.nix), with crate2nix turning Cargo.lock into one
# buildRustCrate derivation per dependency. `nix flake check` runs the tests
# and clippy with warnings denied.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crate2nix = {
      url = "github:nix-community/crate2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crate2nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs.lib.attrsets) optionalAttrs;

      cargoNix = (import "${crate2nix}/tools.nix" { inherit pkgs; }).generatedCargoNix {
        name = "hippo";
        src = self;
      };

      # The crate built with `attrs` added to its own derivation only.
      build =
        attrs:
        (pkgs.callPackage "${cargoNix}/default.nix" {
          buildRustCrateForPkgs =
            pkgs: crate: pkgs.buildRustCrate (crate // optionalAttrs (crate.crateName == "hippo") attrs);
        }).rootCrate.build;
    in
    {
      packages.${system}.default = build { };
      checks.${system} = {
        tests = (build { }).override { runTests = true; };
        clippy = build {
          useClippy = true;
          lints.rust.warnings = "deny";
          # buildRustCrate builds binaries through make without exporting
          # the driver, so they would quietly compile with plain rustc.
          preBuild = "export RUSTC_DRIVER";
        };
        rustfmt = pkgs.runCommand "rustfmt-check" { nativeBuildInputs = [ pkgs.rustfmt ]; } ''
          cd ${self} && rustfmt --edition 2024 --check $(find . -name '*.rs') && touch $out
        '';
      };
      formatter.${system} = pkgs.nixfmt;
    };
}
