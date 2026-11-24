# libri-deploy: put pushed Libri main live on the seat's Libri, as a unit of
# its own.
#
# Libri's workers run inside libri.service, and a deploy restarts it, so a
# deploy a worker ran itself died with it, before its health check and
# rollback (11-03 16:16). Here the deploy runs in its own cgroup, which the
# restart leaves alone, the way switcharoo runs outside what it switches.
#
# - deploy_libri.sh builds the checked-out commit, restarts the services,
#   checks their health, and rolls back on failure. The release gates
#   the push to main on the checks for its change scope.
# - The source is the NAS mirror of GitHub, refreshed first, so only pushed
#   main deploys and nobody's checkout is touched.
# - It runs as the seat, whose polkit rule already lets it restart hippo and
#   Libri; polkit lets the seat start this unit and do nothing else to it.
#   systemd runs one start at a time; a start while one runs joins it.
# - `libri-start-deploy` starts it and returns. Interrupted turns resume
#   after the services restart.
# - The result is in /var/lib/libri-deploy: `status` (commit, start, end,
#   result: live, rolled back, not deployed, already live) and `deploy.log`.
# - libri-ui-latency@VERSION times the released page's interactions against
#   Libri's 400 ms limit after the deploy, outside the release's gate
#   (release_libri.sh says why). `libri-start-ui-latency VERSION` starts it;
#   its result is in /var/lib/libri-deploy: `ui-latency.status` (version,
#   commit, start, end, result: running, pass, fail, and any FAIL lines) and
#   `ui-latency.log`.
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
      inherit (lib.ship) fences;
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
            DEPLOY_LIBRI_ADDONS_DIR=${seat.libriAddonsBuild} \
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
      uiLatency = pkgs.writeShellApplication {
        name = "libri-ui-latency";
        runtimeInputs = [
          config.nix.package
          pkgs.coreutils
          pkgs.git
          pkgs.gnugrep
          pkgs.util-linux
        ];
        text = ''
          version=$1
          checkout=${state}/ui-latency-checkout
          log=${state}/ui-latency.log
          status=${state}/ui-latency.status
          # One run at a time over the checkout and the result; a later
          # release's run waits here for the one before.
          exec 9> ${state}/ui-latency.lock
          flock 9

          [[ -d $checkout/.git ]] || git init --quiet "$checkout"
          # The mirror belongs to another user; git refuses to read it otherwise.
          git -c safe.directory='*' -C "$checkout" fetch --quiet --force ${source} "refs/tags/v$version"
          commit=$(git -C "$checkout" rev-parse 'FETCH_HEAD^{commit}')
          started=$(date -Iseconds)
          printf 'version %s\ncommit %s\nstarted %s\nresult running\n' \
            "$version" "$commit" "$started" > "$status"
          git -C "$checkout" checkout --quiet --force --detach "$commit"
          git -C "$checkout" clean --quiet -ffdx

          code=0
          (cd "$checkout" && nix run .#ui-latency) > "$log" 2>&1 || code=$?
          if ((code == 0)); then result=pass; else result=fail; fi
          {
            printf 'version %s\ncommit %s\nstarted %s\nfinished %s\nresult %s\n' \
              "$version" "$commit" "$started" "$(date -Iseconds)" "$result"
            grep -E '^(FAIL|ok )' "$log" || true
          } > "$status"
          cat "$status"
          exit "$code"
        '';
      };
      startUiLatency = pkgs.writeShellScriptBin "libri-start-ui-latency" ''
        exec ${getExe' pkgs.bash "sh"} ${scripts}/start_ui_latency.sh "$@"
      '';
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
        startUiLatency
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

      systemd.services."libri-ui-latency@" = {
        description = "Time released Libri %i's page against its 400 ms limit";
        # The release's tag reaches the mirror on its refresh.
        wants = singleton "git-mirror@dycli-libri.service";
        # A deploy under way builds and restarts beside it otherwise, and
        # timing would measure the host.
        after = [
          "git-mirror@dycli-libri.service"
          "libri-deploy.service"
        ];
        restartIfChanged = false;
        environment.HOME = seat.home;
        serviceConfig = {
          Type = "oneshot";
          User = seat.user;
          Group = seat.user;
          StateDirectory = "libri-deploy";
          StateDirectoryMode = "0755";
          ExecStart = "${getExe uiLatency} %i";
          Nice = 10;
          # The check stops itself at 90 minutes; the build comes before it.
          TimeoutStartSec = "150min";
          # Libri's own fence: the stand-in host and Chromium talk over
          # loopback, nix fetches from the internet; nothing else.
          IPAddressAllow = fences.loopback;
          IPAddressDeny = fences.internetOnlyDeny ++ singleton "127.0.0.0/8";
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
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit").indexOf("libri-ui-latency@") == 0 &&
              action.lookup("verb") == "start" &&
              subject.user == "${seat.user}") {
            return polkit.Result.YES;
          }
        });
      '';
    };
}
