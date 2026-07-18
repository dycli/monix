{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "fleet-loop-engine";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ../modules/server/fleet-loop;
    filter = path: type: type != "directory" || baseNameOf path != "target";
  };

  cargoLock.lockFile = ../modules/server/fleet-loop/Cargo.lock;

  nativeInstallCheckInputs = [
    pkgs.coreutils
    pkgs.gawk
    pkgs.git
    pkgs.gnugrep
    pkgs.gnutar
    pkgs.zstd
  ];
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/fleet-loop-engine self-test
  '';
  meta.mainProgram = "fleet-loop-engine";
}
