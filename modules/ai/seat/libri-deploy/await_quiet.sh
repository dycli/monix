# Sourced by deploy_libri.sh: await_quiet TASK_URL
# returns once the person's own chats are quiet, or once the wait reaches its
# ceiling.
#
# Only the main turn and a Temp run hold a deploy: the person waits on those.
# Workers don't (Dylan, 11-10): a worker cut off by the restart resumes from
# its log, and workers are at work nearly always, so waiting on them held
# every deploy to the ceiling.
#
# Quiet means no turn or Temp run for ten seconds together, so a message sent
# just after an answer isn't cut off as its turn starts. The wait has a
# ceiling, DEPLOY_QUIET_LIMIT seconds (30 minutes unless set). What happens
# then is the one switch below.

# At the ceiling: "restart" deploys anyway, since a turn cut off resumes
# after the restart (Dylan, 11-02); "stop" ends the deploy without
# restarting.
DEPLOY_AT_LIMIT=${DEPLOY_AT_LIMIT:-restart}
DEPLOY_QUIET_LIMIT=${DEPLOY_QUIET_LIMIT:-1800}

await_quiet() {
  began=$(date +%s)
  quiet=0
  said=
  while [ "$quiet" -lt 10 ]; do
    now=$(curl -s -m5 "$1")
    # The busy list less workers; a build from before `busy` says only
    # whether a turn runs. Drop that fallback once every host serves `busy`.
    left=$(printf '%s' "$now" | jq -c '
      if has("busy") then [.busy[] | select(startswith("worker ") | not)]
      elif .typing == false then [] else null end' 2>/dev/null)
    if [ "$left" = "[]" ]; then
      quiet=$((quiet + 1))
    else
      quiet=0
      busy=$(printf '%s' "$left" |
        jq -r '(. // ["the main turn, or a build too old to say"]) | join(", ")' 2>/dev/null)
      busy=${busy:-no answer from $1}
      # Said when what is at work changes, not every second.
      [ "$busy" = "$said" ] || echo "waiting for $busy $(date +%T)"
      said=$busy
      if [ $(($(date +%s) - began)) -ge "$DEPLOY_QUIET_LIMIT" ]; then
        echo "still at work after ${DEPLOY_QUIET_LIMIT}s: $busy"
        [ "$DEPLOY_AT_LIMIT" = restart ] || return 1
        echo "restarting anyway (DEPLOY_AT_LIMIT=restart)"
        return 0
      fi
    fi
    sleep 1
  done
}
