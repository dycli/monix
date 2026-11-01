# remote_run: heavy work on a fresh boat.dev sandbox instead of on Water.
{ lib, ... }:
let
  inherit (lib.lists) singleton;
  inherit (lib.strings) readFile;
in
{
  flake.homeModules.cockpit =
    { osConfig, pkgs, ... }:
    let
      program = pkgs.writers.writePython3Bin "remote_run" {
        flakeIgnore = [
          "E501"
        ];
      } (readFile ./remote_run.py);
    in
    {
      # nix stays the system's, from PATH, so the client matches the daemon.
      home.packages = singleton (
        pkgs.writeShellApplication {
          name = "remote_run";
          runtimeInputs = with pkgs; [
            coreutils
            git
            gnutar
            openssh
          ];
          text = ''
            export BOAT_KEY_FILE=${osConfig.secrets.boat-api-key.path}
            exec ${lib.getExe program} "$@"
          '';
        }
      );
    };
}
