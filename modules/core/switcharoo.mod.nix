# switcharoo: deploy main as a root unit, test it, and keep it only if the
# host stays healthy.
#
# Patterns from deploy-rs (magic rollback) and comin (pull from git):
#
# - The source is a git remote, never a working tree, so nobody's checkout is
#   touched and only pushed commits deploy. Water reads its own NAS mirror,
#   so a GitHub outage cannot block a deploy there.
# - The new system is first activated with `test`, which leaves the boot
#   menu alone. If activation fails, a unit newly fails, or a required unit
#   isn't running about 30 seconds after the jobs settle, the previous
#   system is reactivated. Only a healthy system becomes the boot default,
#   so a reboot always lands on the last good one.
# - Kernel changes only take effect on reboot, which stays with a human.
# - polkit lets the primary user and the AI seat start `switcharoo.service`
#   and nothing else, with no password. A deploy whose commits touch a fenced
#   file (access, keys, this module) refuses; the captain deploys it with
#   `switcharoo --approve`, which starts `switcharoo-approved.service` and
#   asks for a wheel password. Any module can run root code, so the fence
#   stops accidents, not someone determined.
# - Every deploy is announced through ship-alert where the host has it, and
#   a failed one alerts through the unit-failure drop-in.
#
# In an emergency `nixos-rebuild switch --flake` still works by hand.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.switcharoo;
  flake.nixosModules.switcharoo =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) types;
      inherit (lib.lists) optional singleton;
      inherit (lib.meta) getExe;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep escapeShellArg escapeShellArgs;
      inherit (lib.ship.topology) seat;

      cfg = config.switcharoo;
      host = config.networking.hostName;
      repo = "/var/lib/switcharoo/monix.git";

      deploy = pkgs.writeShellApplication {
        name = "switcharoo-deploy";
        runtimeInputs = [
          config.nix.package
          config.systemd.package
          pkgs.coreutils
          pkgs.git
          pkgs.util-linux
        ];
        text = ''
          approved=''${1:-}
          exec 9>/run/switcharoo.lock
          flock -n 9 || { echo "switcharoo: another deploy is running" >&2; exit 1; }

          # Read from the running system, so after the switch it is the new one's.
          sw=/run/current-system/sw/bin
          announce() {
            if [[ -x $sw/ship-alert ]]; then "$sw/ship-alert"; else cat >/dev/null; fi
          }

          ${lib.strings.optionalString (cfg.refresh != null) ''
            systemctl start ${escapeShellArg cfg.refresh} ||
              echo "switcharoo: couldn't refresh the source; deploying what it has" >&2
          ''}
          [[ -d ${repo} ]] || git init --quiet --bare ${repo}
          # The NAS mirror belongs to another user; git refuses to read it
          # otherwise. Background maintenance would inherit the lock and
          # block the next deploy, so it is off and the lock closed.
          git -c safe.directory='*' -c maintenance.auto=false -c gc.auto=0 \
            -C ${repo} fetch --quiet --force \
            ${escapeShellArg cfg.source} "+refs/heads/main:refs/heads/main" 9>&-
          new=$(git -C ${repo} rev-parse main)
          current=$("$sw/nixos-version" --configuration-revision 2>/dev/null || true)
          current=''${current%-dirty}

          if [[ $current == "$new" ]]; then
            echo "switcharoo: already at ''${new:0:7}"
            exit 0
          fi

          known=0
          if [[ -n $current ]] && git -C ${repo} cat-file -e "$current^{commit}" 2>/dev/null; then
            known=1
            range="''${current:0:7}..''${new:0:7}"
            log=$(git -C ${repo} log --oneline --no-decorate "$current..$new")
          else
            range="unknown..''${new:0:7}"
            log=$(git -C ${repo} log --oneline --no-decorate -1 "$new")
          fi
          echo "switcharoo: deploying $range"
          echo "$log"

          if [[ $approved != approved ]]; then
            if ((!known)); then
              echo "switcharoo: can't tell what changed since the running system; run \`switcharoo --approve\`" >&2
              exit 1
            fi
            fenced=$(git -C ${repo} diff --name-only "$current" "$new" -- ${escapeShellArgs cfg.fenced})
            if [[ -n $fenced ]]; then
              echo "switcharoo: these commits touch fenced files; the captain deploys them with \`switcharoo --approve\`:" >&2
              echo "$fenced" >&2
              exit 1
            fi
          fi

          system=$(nix build --no-link --print-out-paths \
            "git+file://${repo}?ref=main&rev=$new#nixosConfigurations.${host}.config.system.build.toplevel")
          previous=$(readlink -f /run/current-system)
          if [[ $system == "$previous" ]]; then
            echo "switcharoo: the new commits don't change this host"
          fi

          failed() { systemctl list-units --failed --plain --no-legend | cut -d' ' -f1 | sort; }
          before=$(failed)

          healthy=1
          # 4 means only that some unit failed, which the check below judges
          # itself; anything else is a broken activation.
          status=0
          "$system/bin/switch-to-configuration" test || status=$?
          ((status == 0 || status == 4)) || healthy=0

          # Let the jobs settle, then give restarting units time to fail. This
          # unit's own start job stays queued until the script exits, so it
          # doesn't count.
          for _ in $(seq 60); do
            systemctl list-jobs --no-legend | grep -qv ' switcharoo' || break
            sleep 2
          done
          sleep 30
          broke=$(comm -13 <(echo "$before") <(failed))
          # A timer's job runs on its own schedule, and the switch re-arms
          # timers, so one can fire and fail inside this window for reasons
          # of its own (fwupd-refresh while LVFS was down rolled back a sound
          # deploy on 10-21). Its failure alert still reports it.
          broke=$(for unit in $broke; do
            [[ $(systemctl show -P TriggeredBy "$unit") == *.timer* ]] || echo "$unit"
          done)
          [[ -z $broke ]] || healthy=0
          missing=""
          for unit in ${escapeShellArgs cfg.mustRun}; do
            systemctl is-active --quiet "$unit" || missing+="$unit "
          done
          [[ -z $missing ]] || healthy=0

          if ((!healthy)); then
            echo "switcharoo: $range unhealthy; rolling back" >&2
            [[ -z $broke ]] || echo "newly failed: $(echo "$broke" | tr '\n' ' ')" >&2
            [[ -z $missing ]] || echo "not running: $missing" >&2
            "$previous/bin/switch-to-configuration" test
            echo "switcharoo: back on $previous" >&2
            exit 1
          fi

          nix-env --profile /nix/var/nix/profiles/system --set "$system"
          "$system/bin/switch-to-configuration" boot

          note=""
          if [[ $(readlink -f /run/booted-system/kernel) != $(readlink -f "$system/kernel") ]]; then
            note=$'\n🔁 new kernel; it takes effect on reboot'
          fi
          echo "switcharoo: deployed $range"
          printf '🚀 %s: deployed %s\n%s%s' ${host} "$range" "$(head -n 10 <<<"$log")" "$note" | announce
        '';
      };

      unit = description: arg: {
        inherit description;
        # A switch must not restart the unit that is running it.
        restartIfChanged = false;
        environment.HOME = "/root";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${getExe deploy} ${arg}";
          TimeoutStartSec = "2h";
        };
      };

      cli = pkgs.writeShellApplication {
        name = "switcharoo";
        runtimeInputs = [
          config.systemd.package
          pkgs.coreutils
        ];
        text = ''
          unit=switcharoo.service
          start=(systemctl start)
          case "''${1:-}" in
            "") ;;
            # sudo asks in the terminal; polkit would hand the password
            # prompt to the desktop's agent instead.
            --approve) unit=switcharoo-approved.service start=(sudo systemctl start) ;;
            *) echo "usage: switcharoo [--approve]" >&2; exit 2 ;;
          esac
          # Ask before following the journal, so the prompt isn't buried in it.
          [[ $unit == switcharoo.service ]] || sudo -v
          since=$(date '+%Y-%m-%d %H:%M:%S')
          journalctl --follow --output=cat --unit="$unit" --since="$since" &
          follow=$!
          trap 'kill $follow 2>/dev/null' EXIT
          # Queue the deploy and watch it here rather than letting systemctl
          # wait on it: under sudo the waiting systemctl holds the terminal in
          # sudo's raw pty, so the journal's lines lose their carriage returns
          # and staircase, and the switch restarts dbus under a waiting
          # systemctl ("Connection reset by peer") though the deploy goes on.
          "''${start[@]}" --no-block "$unit"
          # A oneshot's start job lasts until the deploy exits, so done is when
          # the unit has no job left. (Its InvocationID won't do: it's empty
          # both before a run and after one.) A failed query (dbus restarting
          # mid-switch) just means ask again.
          until
            jobs=$(systemctl list-jobs --no-legend "$unit" 2>/dev/null) &&
              [[ -z $jobs ]]
          do
            sleep 1
          done
          sleep 1
          [[ $(systemctl show -P Result "$unit") == success ]]
        '';
      };
    in
    {
      options.switcharoo = {
        source = mkOption {
          type = types.str;
          default = "https://github.com/dycli/monix.git";
          description = "Git remote whose main branch this host deploys.";
        };

        refresh = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Unit started before fetching, to bring a local mirror up to date.";
        };

        mustRun = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Units that must be active after a deploy, or it rolls back; hosts add to it.";
        };

        fenced = mkOption {
          type = types.listOf types.str;
          default = [
            "modules/core/switcharoo.mod.nix"
            "modules/core/sudo.mod.nix"
            "modules/core/users.mod.nix"
            "modules/networking/ssh.mod.nix"
            "keys.nix"
            "agenix-rules.nix"
          ];
          description = "Repo paths whose changes only `switcharoo --approve` deploys.";
        };

        users = mkOption {
          type = types.listOf types.str;
          default = [
            config.primaryUser
          ]
          ++ optional (config.users.users ? ${seat.user}) seat.user;
          description = "Users who may start a deploy without a password.";
        };
      };

      config = {
        system.configurationRevision = self.rev or self.dirtyRev or null;

        switcharoo.mustRun = [
          "sshd.service"
        ]
        ++ optional config.services.tailscale.enable "tailscaled.service";

        environment.systemPackages = singleton cli;

        systemd.services.switcharoo = unit "Deploy main from ${cfg.source}" "";
        systemd.services.switcharoo-approved = unit "Deploy main from ${cfg.source}, fenced files included" "approved";

        security.polkit.enable = true;
        security.polkit.extraConfig = ''
          polkit.addRule(function (action, subject) {
            if (action.id == "org.freedesktop.systemd1.manage-units" &&
                action.lookup("unit") == "switcharoo.service" &&
                action.lookup("verb") == "start" &&
                [${concatMapStringsSep ", " (u: ''"${u}"'') cfg.users}].indexOf(subject.user) >= 0) {
              return polkit.Result.YES;
            }
          });
        '';
      };
    };
}
