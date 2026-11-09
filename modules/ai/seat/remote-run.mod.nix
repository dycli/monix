# remote_run: heavy work on a fresh boat.dev sandbox instead of on Water.
{ lib, ... }:
let
  inherit (lib.lists) singleton;
  inherit (lib.meta) getExe;
  inherit (lib.strings) readFile;
in
{
  flake.homeModules.cockpit =
    { pkgs, ... }:
    let
      program = pkgs.writers.writePython3Bin "remote_run" {
        flakeIgnore = singleton "E501";
      } (readFile ./remote_run.py);
    in
    {
      # nix stays the system's, from PATH, so the client matches the daemon.
      home.packages = singleton (
        pkgs.writeShellApplication {
          name = "remote_run";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.git
            pkgs.gnutar
            pkgs.openssh
          ];
          text = ''
            exec ${getExe program} "$@"
          '';
        }
      );
    };
}
