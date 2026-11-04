# libri-deploy: put pushed Libri main live on the seat's Libri, as a unit of
# its own.
#
# Libri's workers run inside libri.service, and a deploy restarts it, so a
# deploy a worker ran itself died with it, before its health check and
# rollback (11-03 16:16). Here the deploy runs in its own cgroup, which the
# restart leaves alone, the way switcharoo runs outside what it switches.
#
# - The logic stays Libri's deploy_libri.sh, run from the commit it deploys:
#   build, wait for quiet, restart, health check, rollback. It runs no
#   checks: main takes only commits the full flake check passed.
# - The source is the NAS mirror of GitHub, refreshed first, so only pushed
#   main deploys and nobody's checkout is touched.
# - It runs as the seat, whose polkit rule already lets it restart hippo and
#   Libri; polkit lets the seat start this unit and do nothing else to it.
#   systemd runs one start at a time; a start while one runs joins it.
# - A worker starts it with `systemctl start --no-block libri-deploy.service`
#   and ends its turn: the deploy waits for quiet, and a worker waiting on it
#   would keep Libri busy until the quiet limit.
# - The result is in /var/lib/libri-deploy: `status` (commit, start, end,
#   result: live, rolled back, not deployed, already live) and `deploy.log`.
{ self, ... }:
{
  flake.nixosModules.seat = self.nixosModules.libri-deploy;
  flake.nixosModules.libri-deploy =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.ship.topology) seat;

      source = "/srv/storage/git/dycli/libri.git";
      state = "/var/lib/libri-deploy";

      deploy = pkgs.writeShellApplication {
        name = "libri-deploy";
        runtimeInputs = [
          config.nix.package
          config.systemd.package
          pkgs.coreutils
          pkgs.curl
          pkgs.git
          pkgs.gnugrep
          pkgs.jq
        ];
        text = ''
          checkout=${state}/libri
          log=${state}/deploy.log
          [[ -d $checkout/.git ]] || git init --quiet "$checkout"
          # The mirror belongs to another user; git refuses to read it otherwise.
          git -c safe.directory='*' -C "$checkout" fetch --quiet --force ${source} main
          new=$(git -C "$checkout" rev-parse FETCH_HEAD)
          started=$(date -Iseconds)

          if [[ $new == "$(cat ${state}/live 2>/dev/null)" ]]; then
            echo "libri-deploy: ''${new:0:7} is already live"
            printf 'commit %s\nstarted %s\nfinished %s\nresult already live\n' \
              "$new" "$started" "$started" > ${state}/status
            exit 0
          fi
          printf 'commit %s\nstarted %s\nresult running\n' "$new" "$started" > ${state}/status
          git -C "$checkout" checkout --quiet --force --detach "$new"
          git -C "$checkout" clean --quiet -ffdx

          status=0
          DEPLOY_LIBRI_LOG=$log DEPLOY_LIBRI_LINK=${seat.libriBuild} \
            sh "$checkout/deploy_libri.sh" || status=$?
          cat "$log"

          if ((status == 0)); then
            result=live
            echo "$new" > ${state}/live
          elif grep -q "new build did not answer" "$log"; then
            result="rolled back"
          else
            result="not deployed"
          fi
          printf 'commit %s\nstarted %s\nfinished %s\nresult %s\n' \
            "$new" "$started" "$(date -Iseconds)" "$result" > ${state}/status
          echo "libri-deploy: ''${new:0:7} $result"
          exit "$status"
        '';
      };
    in
    {
      systemd.services.libri-deploy = {
        description = "Deploy Libri main to the seat's Libri";
        # A start refreshes the mirror first; its failure leaves the last
        # commit it saw.
        wants = singleton "git-mirror.service";
        after = singleton "git-mirror.service";
        # A switch must not stop a deploy under way.
        restartIfChanged = false;
        environment.HOME = seat.home;
        serviceConfig = {
          Type = "oneshot";
          User = seat.user;
          Group = seat.user;
          StateDirectory = "libri-deploy";
          StateDirectoryMode = "0755";
          ExecStart = getExe deploy;
          # The build, then up to deploy_libri.sh's 30-minute quiet wait.
          TimeoutStartSec = "3h";
        };
      };

      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "libri-deploy.service" &&
              action.lookup("verb") == "start" &&
              subject.user == "${seat.user}") {
            return polkit.Result.YES;
          }
        });
      '';
    };
}
