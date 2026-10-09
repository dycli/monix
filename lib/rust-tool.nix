# Builds one of the ship's own crates, named and versioned by its
# Cargo.toml. crate2nix turns Cargo.lock into one buildRustCrate derivation
# per dependency, so an edit rebuilds only the crate itself. `check = true`
# gives the `nix flake check` gate instead: the tests run, and clippy lints
# the crate with warnings denied.
lib: crate2nix: pkgs:
{
  src,
  env ? { },
  check ? false,
  nativeCheckInputs ? [ ],
}:
let
  inherit (lib.attrsets) optionalAttrs;

  manifest = (lib.trivial.importTOML "${src}/Cargo.toml").package;

  cargoNix = (import "${crate2nix}/tools.nix" { inherit pkgs; }).generatedCargoNix {
    inherit (manifest) name;
    inherit src;
  };

  # Fixes for dependencies that expect something buildRustCrate lacks.
  crateOverrides = pkgs.defaultCrateOverrides // {
    # Cargo sets CARGO_CRATE_NAME; buildRustCrate does not.
    rmcp = _: { env.CARGO_CRATE_NAME = "rmcp"; };
  };

  # The crate built with `attrs` added to its own derivation only.
  build =
    attrs:
    (pkgs.callPackage "${cargoNix}/default.nix" {
      buildRustCrateForPkgs =
        pkgs: crate:
        pkgs.buildRustCrate.override { defaultCrateOverrides = crateOverrides; } (
          crate // optionalAttrs (crate.crateName == manifest.name) attrs
        );
    }).rootCrate.build;
in
if check then
  pkgs.linkFarm "${manifest.name}-check" {
    tests = (build { }).override {
      runTests = true;
      testInputs = nativeCheckInputs;
    };
    clippy = build {
      useClippy = true;
      lints.rust.warnings = "deny";
      # buildRustCrate builds binaries through make without exporting the
      # driver, so they would quietly compile with plain rustc.
      preBuild = "export RUSTC_DRIVER";
    };
  }
else
  build { inherit env; }
