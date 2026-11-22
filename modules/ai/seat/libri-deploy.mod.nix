# libri-deploy: put pushed Libri main live on the seat's Libri, as a unit of
# its own.
#
# Libri's workers run inside libri.service, and a deploy restarts it, so a
# deploy a worker ran itself died with it, before its health check and
# rollback (11-03 16:16). Here the deploy runs in its own cgroup, which the
# restart leaves alone, the way switcharoo runs outside what it switches.
#
# - deploy_libri.sh builds the checked-out commit, restarts the services,
#   checks their health, and rolls back on failure. The release runs the full
#   flake check before it pushes to main.
# - The source is the NAS mirror of GitHub, refreshed first, so only pushed
#   main deploys and nobody's checkout is touched.
# - It runs as the seat, whose polkit rule already lets it restart hippo and
#   Libri; polkit lets the seat start this unit and do nothing else to it.
#   systemd runs one start at a time; a start while one runs joins it.
# - `libri-start-deploy` starts it and returns. Interrupted turns resume
#   after the services restart.
# - The result is in /var/lib/libri-deploy: `status` (commit, start, end,
#   result: live, rolled back, not deployed, already live) and `deploy.log`.
{ self, ... }:
let
  scripts = ./libri-deploy;
in
{
  perSystem =
    { pkgs, ... }:
    {
      # Each way a deploy can end, played out with nix, systemctl and curl
      # stood in for.
      checks.libri-deploy =
        pkgs.runCommand "libri-deploy-check"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.git
            ];
          }
          ''
            export HOME=$TMPDIR
            python3 -I ${scripts}/check_deploy.py ${scripts}/deploy_libri.sh
            touch $out
          '';
    };

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
      inherit (lib.meta) getExe getExe';
      inherit (lib.ship.topology) seat;

      source = "/srv/storage/git/dycli/libri.git";
      state = "/var/lib/libri-deploy";

      deploy = pkgs.writeShellApplication {
        name = "libri-deploy";
        runtimeInputs = [
          config.nix.package
          config.systemd.package
          # deploy_libri.sh runs under sh; the unit's PATH has none otherwise.
          pkgs.bash
          pkgs.coreutils
          pkgs.curl
          pkgs.git
          pkgs.gnugrep
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
            sh ${scripts}/deploy_libri.sh "$checkout" || status=$?
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
      startDeploy = pkgs.writeShellScriptBin "libri-start-deploy" ''
        exec ${getExe' pkgs.bash "sh"} ${scripts}/start_deploy.sh "$@"
      '';
      # cmark renders the privacy policy (publish_android.sh).
      publishAndroid = pkgs.writeShellScriptBin "libri-publish-android" ''
        PATH=${pkgs.cmark}/bin:$PATH exec ${getExe pkgs.bash} ${scripts}/publish_android.sh "$@"
      '';
      # Reports where the phone web and Android drift apart since a tag; the
      # release runs it for its notes.
      parity = pkgs.writeShellScriptBin "libri-parity" ''
        exec ${getExe pkgs.bash} ${scripts}/review_parity.sh "$@"
      '';
      # Bridge's review of a worker branch before it merges to main.
      review = pkgs.writeShellScriptBin "libri-review" ''
        exec ${getExe pkgs.bash} ${scripts}/review_branch.sh "$@"
      '';
      # The one release command; it calls libri-start-deploy,
      # libri-publish-android and libri-parity from the seat's PATH.
      release = pkgs.writeShellScriptBin "libri-release" ''
        exec ${getExe pkgs.bash} ${scripts}/release_libri.sh "$@"
      '';
    in
    {
      environment.systemPackages = [
        startDeploy
        publishAndroid
        parity
        review
        release
      ];

      systemd.services.libri-deploy = {
        description = "Deploy Libri main to the seat's Libri";
        # A start refreshes the mirror first; its failure leaves the last
        # commit it saw.
        wants = singleton "git-mirror@dycli-libri.service";
        after = singleton "git-mirror@dycli-libri.service";
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
          # Allow for a cold build and the service restart and health checks.
          TimeoutStartSec = "150min";
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
