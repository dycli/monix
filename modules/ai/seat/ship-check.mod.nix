# ship-check: monix's checks on the host, each in its own nix process, all
# at once. Nix evaluates single-threaded, so one process building every
# check takes the sum of the hosts' evaluations (40 s); a process per check
# run together takes the slowest one (25 s against 80 s run in turn,
# measured 11-12). Each host's evaluation peaks near 3 GB, which Water's
# 96 GB carries; the lock still makes a second check wait for the first, so
# two agents checking at once don't double that.
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
              names=(${lib.strings.concatStringsSep " " (lib.attrsets.attrNames self.checks.x86_64-linux)})
            else
              names=()
              for name in "$@" rustfmt nixfmt nix-style secrets-rules; do
                case $name in
                  air | earth | fire | water) name=host-$name ;;
                esac
                names+=("$name")
              done
            fi
            # Each check's log goes to its own file, shown only if it fails,
            # so parallel output doesn't interleave.
            logs=$(mktemp -d)
            trap 'rm -rf "$logs"' EXIT
            declare -A pids
            for name in "''${names[@]}"; do
              [[ -v pids[$name] ]] && continue
              nix build --no-link ".#checks.x86_64-linux.$name" >"$logs/$name" 2>&1 &
              pids[$name]=$!
            done
            failed=()
            for name in "''${!pids[@]}"; do
              if wait "''${pids[$name]}"; then
                echo "ship-check: $name ok" >&2
              else
                failed+=("$name")
              fi
            done
            for name in "''${failed[@]}"; do
              echo "ship-check: $name FAILED" >&2
              tail -n 40 "$logs/$name" >&2
            done
            ((''${#failed[@]} == 0))
          '';
        }
      );
    };
}
