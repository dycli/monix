#!/bin/sh
# Usage: deploy_libri.sh CHECKOUT
# Deploys the Libri commit checked out at CHECKOUT on Water to every instance there, the seat's
# (libri) and Gab's (suki), which run the one build: builds, waits until
# neither is at work, restarts both, and puts both back on the previous build
# if either doesn't answer. A restart kills a turn under way, and with it the
# answer the person is waiting for, so it waits for a quiet moment.
# It runs no checks: main takes only commits the full `nix flake check`
# passed, and that check built these same crates, so the build below finds
# them in the store and adds only the wrappers.
# It runs as libri-deploy.service (libri-deploy.mod.nix beside it), on a
# checkout of the pushed commit it deploys: started from inside libri.service,
# the restart below would kill it before its health check. It logs to the file
# below. It lives in monix, not in Libri: Libri holds the product only.
LOG=${DEPLOY_LIBRI_LOG:-/tmp/deploy_libri.log}
# The unit runs from LINK, restarting on its own if it dies, so LINK moves
# only once quiet: until then the new build waits at STAGE, and a crash or a
# killed deploy leaves the old build running.
LINK=${DEPLOY_LIBRI_LINK:-/var/lib/libri-build/libri}
STAGE=$LINK.next
# Each instance's unit and port. Suki's hippo is her daemon's child, as on
# any install; the seat's is a unit of its own, as it keeps the cockpit's
# chats too.
INSTANCES=${DEPLOY_LIBRI_INSTANCES:-libri:8951 suki:8952}
HIPPOS=${DEPLOY_LIBRI_HIPPOS:-hippo}

# The worker that started this deploy, if start_deploy.sh named one: its run
# doesn't hold the deploy. Read once and removed, and only if fresh, so a
# name left by a deploy that never ran doesn't excuse a later one's worker.
STARTER_FILE=${DEPLOY_LIBRI_STARTER:-/var/lib/libri-deploy/starter}
STARTER=
[ -n "$(find "$STARTER_FILE" -mmin -10 2>/dev/null)" ] && STARTER=$(head -n1 "$STARTER_FILE")
rm -f "$STARTER_FILE"
# libri-start-deploy --now leaves this: the quiet wait ends as soon as it
# appears, before this deploy or during its wait. One older than ten minutes
# is left from a deploy that never ran, and doesn't hurry this one.
NOW_FILE=${DEPLOY_LIBRI_NOW:-/var/lib/libri-deploy/now}
[ -z "$(find "$NOW_FILE" -mmin +10 2>/dev/null)" ] || rm -f "$NOW_FILE"

here=$(cd "$(dirname "$0")" && pwd)
exec > "$LOG" 2>&1
cd "${1:?usage: deploy_libri.sh CHECKOUT}" || exit 1
. "$here/await_quiet.sh"
[ -z "$STARTER" ] || echo "started by worker $STARTER, whose run doesn't hold it"
echo "deploying $(git rev-parse --short HEAD) $(date +%T)"
previous=$(readlink "$LINK")
nix build .#default -o "$STAGE" || { echo "build failed, not deployed"; exit 1; }
built=$(readlink "$STAGE")
echo "built $built"

# Each in turn. A turn that starts on one while the other is awaited is cut
# by the restart, and resumes after it, as any turn at the ceiling does.
for i in $INSTANCES; do
  if ! await_quiet "http://127.0.0.1:${i##*:}/api/task" "$STARTER" "$NOW_FILE"; then
    echo "not deployed; nothing restarted"
    rm -f "$STAGE"
    exit 1
  fi
done
rm -f "$NOW_FILE"
# nix build, not ln, so the link is a GC root on a host this script never
# deployed to before.
nix build "$built" -o "$LINK" || { echo "link not moved, not deployed"; rm -f "$STAGE"; exit 1; }
rm -f "$STAGE"

echo "restarting $(date +%T)"
# A hippo unit runs from the same build; its store outlives any restart, and
# Libri waits for it, so it restarts only when the binary changed.
# HIPPO_RAN names the binary the last restart started, not the link's old
# target: a deploy killed after moving the link would leave old and new the
# same, and the rerun would leave the old hippo running.
HIPPO_RAN=$LINK.hippo
restart() {
  hippo=$(readlink -f "$LINK/bin/hippo")
  if [ "$(cat "$HIPPO_RAN" 2>/dev/null)" != "$hippo" ]; then
    ok=1
    for h in $HIPPOS; do
      systemctl restart "$h.service" || ok=
    done
    [ -z "$ok" ] || echo "$hippo" > "$HIPPO_RAN"
  fi
  for i in $INSTANCES; do
    systemctl restart "${i%%:*}.service"
  done
}
# Whether every instance answers within 30 seconds.
answers() {
  for i in $INSTANCES; do
    host="http://127.0.0.1:${i##*:}/api/host"
    up=
    for _ in $(seq 30); do
      if [ "$(curl -s -m3 -o /dev/null -w '%{http_code}' "$host")" = "200" ]; then
        up=1
        break
      fi
      sleep 1
    done
    [ -n "$up" ] || { echo "${i%%:*} did not answer"; return 1; }
  done
}
restart
if answers; then
  echo "live $(date +%T)"
  exit 0
fi
echo "new build did not answer; back to $previous"
nix build "$previous" -o "$LINK"
restart
exit 1
