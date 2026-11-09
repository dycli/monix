# ship-check: monix's checks, one at a time on the host, each in its own
# nix process. One process evaluating all four hosts peaked at 4.9 GB; one
# per check peaks at the largest host, 3.0 GB, for twice the evaluation time
# (52 s, 2026-11-03). Two checks at once ran Water out of memory on
# 2026-10-17 and froze it on 2026-10-22, so the lock makes a second check
# wait for the first.
#
# `ship-check` alone builds every check. Named checks build only those, plus
# the cheap style gates: `ship-check money water` for a change inside a
# crate. A host name stands for its system build.
{ self, lib, ... }:
{
  flake.nixosModules.seat = self.nixosModules.ship-check;
  flake.nixosModules.ship-check = {
    # Every user's check takes the same lock, so it lives outside /tmp,
    # which some units keep private.
    systemd.tmpfiles.rules = lib.lists.singleton "f /run/ship-check.lock 0666 root root -";
  };

  flake.homeModules.cockpit =
    { lib, pkgs, ... }:
    {
      home.packages = lib.lists.singleton (
        pkgs.writeShellApplication {
          name = "ship-check";
          runtimeInputs = lib.lists.singleton pkgs.util-linux;
          text = ''
            exec 9>/run/ship-check.lock
            if ! flock -n 9; then
              echo "ship-check: another check is running; waiting for it" >&2
              flock 9
            fi
            if [ $# -eq 0 ]; then
              for name in ${lib.strings.concatStringsSep " " (lib.attrsets.attrNames self.checks.x86_64-linux)}; do
                echo "ship-check: $name" >&2
                nix build --no-link ".#checks.x86_64-linux.$name"
              done
              exit
            fi
            targets=()
            for name in "$@" rustfmt nixfmt nix-style secrets-rules; do
              case $name in
                air | earth | fire | water) name=host-$name ;;
              esac
              targets+=(".#checks.x86_64-linux.$name")
            done
            exec nix build --no-link "''${targets[@]}"
          '';
        }
      );
    };
}
