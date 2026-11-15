# switcharoo: deploy main as a root job, test it, and keep it only if the
# host stays healthy.
#
# Patterns from deploy-rs (magic rollback) and comin (pull from git):
#
# - The source is a git remote, never a working tree, so nobody's checkout is
#   touched and only pushed commits deploy. Water reads its own NAS mirror,
#   so a GitHub outage cannot block a deploy there.
# - The new system is first activated without becoming the boot default
#   (`switch-to-configuration test` on NixOS, `activate` on Darwin). If
#   activation fails, a job newly fails, or a required job isn't running
#   about 30 seconds later, the previous system is reactivated. Only a
#   healthy system becomes the boot default, so a reboot always lands on the
#   last good one.
# - Kernel changes only take effect on reboot, which stays with a human.
# - The primary user (and on NixOS the AI seat) may start the deploy job and
#   nothing else with no password: polkit on NixOS, one exact sudoers line on
#   Darwin. A deploy whose commits touch a fenced file (access, keys, this
#   module) refuses; the captain deploys it with `switcharoo --approve`,
#   which starts the approved job and asks for an administrator's password.
#   Any module can run root code, so the fence stops accidents, not someone
#   determined.
# - Every deploy is announced through ship-alert where the host has it, and
#   on NixOS a failed one alerts through the unit-failure drop-in.
#
# In an emergency `nixos-rebuild switch --flake` or
# `darwin-rebuild switch --flake` still works by hand.
{ self, ... }:
let
  # The deploy job's launchd labels on Darwin.
  darwinLabel = "org.nixos.switcharoo";
  darwinApprovedLabel = "org.nixos.switcharoo-approved";
  darwinLog = "/var/log/switcharoo.log";
in
{
  flake.commonModules.default = self.commonModules.switcharoo;
  flake.commonModules.switcharoo =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) types;
      inherit (lib.lists) optional singleton;
      inherit (lib.options) mkOption;
      inherit (lib.strings) escapeShellArg escapeShellArgs;
      inherit (lib.ship.topology) seat;

      cfg = config.switcharoo;
      host = config.networking.hostName;
      repo = "/var/lib/switcharoo/monix.git";
      refresh = cfg.refresh or null;

      # What differs between the platforms; the deploy and the CLI are
      # otherwise one script.
      platform =
        if pkgs.stdenv.hostPlatform.isDarwin then
          {
            deployInputs = [
              config.nix.package
              pkgs.coreutils
              pkgs.flock
              pkgs.git
              pkgs.gnugrep
              pkgs.gnused
            ];
            version = "darwin-version";
            configurations = "darwinConfigurations";
            # Only the daemons this system defines, so macOS's own jobs can't
            # fail a deploy. A calendar job runs on its own schedule, as a
            # timer does on NixOS, so it is left to its own alerting.
            failed = ''
              failed() {
                for plist in "$system"/Library/LaunchDaemons/*.plist; do
                  grep -q StartCalendarInterval "$plist" && continue
                  label=$(basename "$plist" .plist)
                  code=$(/bin/launchctl print "system/$label" 2>/dev/null | sed -n 's/^\tlast exit code = //p')
                  [[ -z $code || $code == 0 || $code == "(never exited)" ]] || echo "$label"
                done | sort
              }'';
            activate = ''
              "$system/activate" || healthy=0

              # launchd has no job queue to wait on; give restarting daemons
              # time to fail.
              sleep 30
              broke=$(comm -13 <(echo "$before") <(failed))'';
            isRunning = ''/bin/launchctl print "system/$unit" 2>/dev/null | grep -qx $'\tstate = running' '';
            # sshd starts per connection, so its job is never running between
            # them; it is judged by its config and launchd's listening socket.
            # The tailnet is the only way in from away.
            probes = ''
              /usr/sbin/sshd -t || missing+="sshd-config "
              /usr/bin/nc -z -G 5 127.0.0.1 22 || missing+="sshd-port "
              ${lib.strings.optionalString config.services.tailscale.enable ''
                "$sw/tailscale" status >/dev/null || missing+="tailnet "
              ''}'';
            rollback = ''"$previous/activate"'';
            # At boot activate-system reactivates whatever the profile names,
            # so setting it makes the system the boot default.
            commit = ''
              nix-env --profile /nix/var/nix/profiles/system --set "$system"

              note=""'';
          }
        else
          {
            deployInputs = [
              config.nix.package
              config.systemd.package
              pkgs.coreutils
              pkgs.git
              pkgs.util-linux
            ];
            version = "nixos-version";
            configurations = "nixosConfigurations";
            failed = "failed() { systemctl list-units --failed --plain --no-legend | cut -d' ' -f1 | sort; }";
            activate = ''
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
              done)'';
            isRunning = ''systemctl is-active --quiet "$unit"'';
            probes = "";
            rollback = ''"$previous/bin/switch-to-configuration" test'';
            commit = ''
              nix-env --profile /nix/var/nix/profiles/system --set "$system"
              "$system/bin/switch-to-configuration" boot

              note=""
              if [[ $(readlink -f /run/booted-system/kernel) != $(readlink -f "$system/kernel") ]]; then
                note=$'\n🔁 new kernel; it takes effect on reboot'
              fi'';
          };

      deploy = pkgs.writeShellApplication {
        name = "switcharoo-deploy";
        runtimeInputs = platform.deployInputs;
        text = ''
          approved=''${1:-}
          exec 9>/run/switcharoo.lock
          flock -n 9 || { echo "switcharoo: another deploy is running" >&2; exit 1; }

          # Read from the running system, so after the switch it is the new one's.
          sw=/run/current-system/sw/bin
          announce() {
            if [[ -x $sw/ship-alert ]]; then "$sw/ship-alert"; else cat >/dev/null; fi
          }

          ${lib.strings.optionalString (refresh != null) ''
            systemctl start ${escapeShellArg refresh} ||
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
          current=$("$sw/${platform.version}" --configuration-revision 2>/dev/null || true)
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
            "git+file://${repo}?ref=main&rev=$new#${platform.configurations}.${host}.config.system.build.toplevel")
          previous=$(readlink -f /run/current-system)
          if [[ $system == "$previous" ]]; then
            echo "switcharoo: the new commits don't change this host"
          fi

          ${platform.failed}
          before=$(failed)

          healthy=1
          ${platform.activate}
          [[ -z $broke ]] || healthy=0
          # Judge the new generation by its own list, so a deploy that retires
          # a service isn't failed for no longer running it.
          mapfile -t must < "$system/etc/switcharoo/must-run"
          missing=""
          for unit in "''${must[@]}"; do
            ${platform.isRunning} || missing+="$unit "
          done
          ${platform.probes}[[ -z $missing ]] || healthy=0

          if ((!healthy)); then
            echo "switcharoo: $range unhealthy; rolling back" >&2
            [[ -z $broke ]] || echo "newly failed: $(echo "$broke" | tr '\n' ' ')" >&2
            [[ -z $missing ]] || echo "not running: $missing" >&2
            ${platform.rollback}
            echo "switcharoo: back on $previous" >&2
            exit 1
          fi

          ${platform.commit}
          echo "switcharoo: deployed $range"
          printf '🚀 %s: deployed %s\n%s%s' ${host} "$range" "$(head -n 10 <<<"$log")" "$note" | announce
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

        mustRun = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Jobs (systemd units, or launchd labels on Darwin) that must be running after a deploy, or it rolls back; hosts add to it.";
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
          default = singleton config.primaryUser ++ optional (config.users.users ? ${seat.user}) seat.user;
          description = "Users who may start a deploy without a password.";
        };

        deploy = mkOption {
          type = types.package;
          internal = true;
          readOnly = true;
          default = deploy;
          description = "The deploy script the platform's jobs run.";
        };
      };

      config = {
        system.configurationRevision = self.rev or self.dirtyRev or null;

        environment.etc."switcharoo/must-run".text = lib.strings.concatLines cfg.mustRun;
      };
    };

  flake.nixosModules.default = self.nixosModules.switcharoo-linux;
  flake.nixosModules.switcharoo-linux =
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
      inherit (lib.strings) concatMapStringsSep;

      cfg = config.switcharoo;

      unit = description: arg: {
        inherit description;
        # A switch must not restart the unit that is running it.
        restartIfChanged = false;
        environment.HOME = "/root";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${getExe cfg.deploy} ${arg}";
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
      options.switcharoo.refresh = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Unit started before fetching, to bring a local mirror up to date.";
      };

      config = {
        switcharoo.mustRun =
          singleton "sshd.service" ++ optional config.services.tailscale.enable "tailscaled.service";

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

  flake.darwinModules.default = self.darwinModules.switcharoo-darwin;
  flake.darwinModules.switcharoo-darwin =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) optional;
      inherit (lib.strings) concatMapStrings;

      cfg = config.switcharoo;

      # Activation reloads every daemon whose plist changed, which would kill
      # the deploy running it, so the plist names the deploy by its stable
      # path in the running system rather than by its store path. A running
      # deploy keeps the script it started with.
      job = arg: {
        serviceConfig = {
          ProgramArguments = [ "/run/current-system/sw/bin/switcharoo-deploy" ] ++ optional (arg != "") arg;
          # launchd passes no environment; git and Nix need the CA bundle
          # nix-darwin installs to fetch over HTTPS.
          EnvironmentVariables = {
            HOME = "/var/root";
            SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
          };
          StandardOutPath = darwinLog;
          StandardErrorPath = darwinLog;
        };
      };

      cli = pkgs.writeShellApplication {
        name = "switcharoo";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
        ];
        text = ''
          label=${darwinLabel}
          # -n: the sudoers rule admits this exact command with no password.
          kick=(sudo -n /bin/launchctl kickstart)
          case "''${1:-}" in
            "") ;;
            --approve) label=${darwinApprovedLabel} kick=(sudo /bin/launchctl kickstart) ;;
            *) echo "usage: switcharoo [--approve]" >&2; exit 2 ;;
          esac
          # Ask before following the log, so the prompt isn't buried in it.
          [[ $label == ${darwinLabel} ]] || sudo -v
          # One snapshot per poll, so runs and state come from the same moment.
          # A failed print leaves the fields empty, which reads as not yet.
          poll() { info=$(/bin/launchctl print "system/$label" 2>/dev/null) || info=""; }
          field() { sed -n "s/^\t$1 = //p" <<<"$info"; }

          offset=$(stat -c %s ${darwinLog} 2>/dev/null || echo 0)
          tail -c "+$((offset + 1))" -F ${darwinLog} 2>/dev/null &
          follow=$!
          trap 'kill $follow 2>/dev/null' EXIT

          # launchd counts the job's runs; the run to follow is the next one.
          # kickstart of a running job starts nothing and still exits 0, so a
          # deploy already running is followed as the one the CLI would start,
          # as systemctl start joins a running oneshot.
          poll
          runs=$(field runs)
          target=$((''${runs:-0} + 1))
          if [[ $(field state) == running ]]; then
            target=''${runs:-0}
            echo "switcharoo: a deploy is already running; following it" >&2
          else
            # kickstart waits out launchd's ten-second minimum between runs.
            timeout --foreground 60 "''${kick[@]}" "system/$label" ||
              { echo "switcharoo: launchctl kickstart system/$label failed or did not return within 60 s" >&2; exit 1; }
          fi

          # A run counts as begun once launchd reports it running or counts it;
          # the two-hour limit matches the deploy unit's on NixOS.
          begin_by=$((SECONDS + 60))
          end_by=$((SECONDS + 7200))
          while
            poll
            n=$(field runs)
            [[ $(field state) == running ]] || ((''${n:-0} < target))
          do
            if [[ $(field state) != running ]] && ((SECONDS > begin_by)); then
              echo "switcharoo: launchd has not started $label after 60 s; see launchctl print system/$label" >&2
              exit 124
            fi
            if ((SECONDS > end_by)); then
              echo "switcharoo: the deploy is still running after two hours; it goes on, and its log is ${darwinLog}" >&2
              exit 124
            fi
            sleep 1
          done
          sleep 1

          code=$(field "last exit code")
          if [[ $code =~ ^[0-9]+$ ]]; then
            exit "$code"
          fi
          echo "switcharoo: launchd reports the deploy's last exit code as: $code" >&2
          exit 1
        '';
      };
    in
    {
      switcharoo.mustRun = optional config.services.tailscale.enable config.launchd.daemons.tailscaled.serviceConfig.Label;

      environment.systemPackages = [
        cli
        cfg.deploy
      ];

      launchd.daemons.switcharoo = job "";
      launchd.daemons.switcharoo-approved = job "approved";

      # Keeps five rotated logs of a megabyte each.
      environment.etc."newsyslog.d/switcharoo.conf".text = ''
        ${darwinLog} 644 5 1024 * J
      '';

      # sudoers matches the arguments exactly, so this admits the plain
      # deploy alone; the approved job still asks for a password.
      security.sudo.extraConfig = concatMapStrings (
        user: "${user} ALL=(root) NOPASSWD: /bin/launchctl kickstart system/${darwinLabel}\n"
      ) cfg.users;
    };
}
