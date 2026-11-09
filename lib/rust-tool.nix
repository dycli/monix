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
  inherit (lib.lists) singleton;

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
  let
    # The gate wants verdicts, not fast code: the crate itself compiles
    # unoptimised (its dependencies stay the release builds the hosts use),
    # and without the full debuginfo buildRustCrate gives a debug build,
    # which costs rustc memory and time and which no test failure prints.
    # Tests keep line tables, for their backtraces.
    harness = build {
      release = false;
      buildTests = true;
      extraRustcOpts = singleton "-C debuginfo=line-tables-only";
    };
  in
  pkgs.linkFarm "${manifest.name}-check" {
    # The test harness alone, run from the source tree as Cargo runs it.
    # crate2nix's runTests also compiles the crate's binaries, to copy beside
    # the harness for tests that run them; none of these tests do.
    tests = pkgs.stdenvNoCC.mkDerivation {
      name = "${manifest.name}-tests";
      # The harness's own source, unpacked where it was compiled, so
      # CARGO_MANIFEST_DIR still leads to the crate's test fixtures.
      inherit (harness) src;
      nativeBuildInputs = nativeCheckInputs;
      buildPhase = ''
        set -o pipefail
        export RUST_BACKTRACE=1
        for test in ${harness}/tests/*; do
          "$test" 2>&1 | tee -a $out
        done
      '';
      dontInstall = true;
    };
    clippy = build {
      release = false;
      useClippy = true;
      lints.rust.warnings = "deny";
      extraRustcOpts = singleton "-C debuginfo=0";
      # buildRustCrate builds binaries through make without exporting the
      # driver, so they would quietly compile with plain rustc.
      preBuild = "export RUSTC_DRIVER";
    };
  }
else
  build { inherit env; }
