# Agent-fleet dispatcher. See docs/agent-fleet.md. Turns the fleet into a
# drop-a-file service: a task is a markdown prompt placed in the queue
# directory; the dispatcher runs it on a pristine worker VM and collects the
# report — no SSH into guests, no forge in the loop.
#
#   /var/lib/agents/tasks/queue/<name>.md   <- drop tasks here (wheel-writable;
#                                              write elsewhere and `mv` in, so
#                                              a half-written file is never seen)
#   /var/lib/agents/tasks/done/<id>/        <- prompt.md + report.md + agent.log
#   /var/lib/agents/tasks/failed/<id>/      <- same, for nonzero exit or timeout
#
# A path unit fires when the queue becomes non-empty; the dispatcher drains
# it serially on the first roster worker: stage prompt into the worker's
# task share, restart the VM (volume wipe makes it pristine), poll for the
# guest's exit-code file, stop the VM, file the results. The dispatcher owns
# worker lifecycle — a manually started VM will be restarted out from under
# you when a task arrives.
{
  flake.nixosModules.agent-dispatch =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) head;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib) types;

      cfg = config.agentFleet;

      tasksDir = "/var/lib/agents/tasks";
    in
    {
      options.agentFleet.taskTimeout = mkOption {
        type = types.int;
        default = 5400;
        description = "seconds a task may run before the worker is stopped and the task filed as failed";
      };

      config = mkIf (cfg.enable && cfg.workers != [ ]) {
        systemd.tmpfiles.rules = [
          "d ${tasksDir} 0755 root root -"
          # The cockpit user (wheel) drops tasks and reads results.
          "d ${tasksDir}/queue 0770 root wheel -"
          "d ${tasksDir}/running 0755 root root -"
          "d ${tasksDir}/done 0755 root root -"
          "d ${tasksDir}/failed 0755 root root -"
        ];

        systemd.paths.agent-dispatcher = {
          description = "Watch the agent task queue";
          wantedBy = [ "multi-user.target" ];
          pathConfig.DirectoryNotEmpty = "${tasksDir}/queue";
        };

        systemd.services.agent-dispatcher = {
          description = "Dispatch queued tasks to agent workers";
          path = [
            pkgs.coreutils
            pkgs.systemd
          ];
          serviceConfig = {
            Type = "oneshot";
            Slice = "agents.slice";
          };
          script =
            let
              worker = (head cfg.workers).name;
              work = "/var/lib/agents/work/${worker}/task";
            in
            ''
              queue=${tasksDir}/queue
              running=${tasksDir}/running
              work=${work}

              reset_work() {
                rm -rf "$work"
                install -d -m 0755 -o 1000 -g 100 "$work"
              }

              while :; do
                set -- "$queue"/*.md
                if [ ! -e "$1" ]; then
                  break
                fi
                id="$(basename "$1" .md)-$(date +%Y%m%d-%H%M%S)"
                echo "dispatching $id to ${worker}"
                mv "$1" "$running/$id.md"

                reset_work
                install -m 0444 "$running/$id.md" "$work/prompt.md"
                systemctl restart microvm@${worker}.service

                deadline=$(( $(date +%s) + ${toString cfg.taskTimeout} ))
                status=timeout
                while [ "$(date +%s)" -lt "$deadline" ]; do
                  if [ -f "$work/exit-code" ]; then
                    if [ "$(cat "$work/exit-code")" = 0 ]; then
                      status=done
                    else
                      status=failed
                    fi
                    break
                  fi
                  sleep 10
                done
                systemctl stop microvm@${worker}.service

                if [ "$status" = done ]; then
                  out=${tasksDir}/done/$id
                else
                  out=${tasksDir}/failed/$id
                fi
                install -d "$out"
                mv "$running/$id.md" "$out/prompt.md"
                for f in report.md agent.log exit-code; do
                  if [ -f "$work/$f" ]; then
                    install -m 0644 "$work/$f" "$out/$f"
                  fi
                done
                reset_work
                echo "$id finished: $status -> $out"
              done
            '';
        };
      };
    };
}
