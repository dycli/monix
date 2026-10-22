# ship-check: monix's checks, one at a time on the host. A full check
# evaluates every host (~10 GB) and builds each crate three times; two at
# once ran Water out of memory on 2026-10-17 and froze it on 2026-10-22.
# The lock makes a second check wait for the first instead.
#
# `ship-check` alone runs `nix flake check`. Named checks build only those,
# plus the cheap style gates: `ship-check yeoman water` for a change inside
# yeoman's crate. A host name stands for its system build.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.ship-check;
  flake.nixosModules.ship-check = {
    # Every user's check takes the same lock, so it lives outside /tmp,
    # which some units keep private.
    systemd.tmpfiles.rules = [ "f /run/ship-check.lock 0666 root root -" ];
  };

  flake.homeModules.cockpit =
    { lib, pkgs, ... }:
    {
      home.packages = lib.lists.singleton (
        pkgs.writeShellApplication {
          name = "ship-check";
          runtimeInputs = [ pkgs.util-linux ];
          text = ''
            exec 9>/run/ship-check.lock
            if ! flock -n 9; then
              echo "ship-check: another check is running; waiting for it" >&2
              flock 9
            fi
            if [ $# -eq 0 ]; then
              exec nix flake check
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
