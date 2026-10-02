# Builds one of the ship's own crates, named and versioned by its
# Cargo.toml. Production builds skip the tests; `check = true` gives the
# `nix flake check` gate, which runs them and lints with clippy.
lib: pkgs:
{
  src,
  env ? { },
  check ? false,
  nativeCheckInputs ? [ ],
}:
let
  inherit (lib.attrsets) optionalAttrs;

  manifest = (lib.trivial.importTOML "${src}/Cargo.toml").package;
in
pkgs.rustPlatform.buildRustPackage (
  {
    pname = if check then "${manifest.name}-check" else manifest.name;
    inherit (manifest) version;
    inherit src env;
    cargoLock.lockFile = "${src}/Cargo.lock";
    doCheck = check;
    meta.mainProgram = manifest.name;
  }
  // optionalAttrs check {
    inherit nativeCheckInputs;
    nativeBuildInputs = lib.lists.singleton pkgs.clippy;
    postCheck = "cargo clippy --all-targets -- -D warnings";
  }
)
