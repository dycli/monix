#!/bin/sh
# Usage: deploy_libri.sh CHECKOUT
# Deploys the Libri commit checked out at CHECKOUT on Water to Libri, Suki,
# and the core daemon. Interrupted turns resume after the restart.
# The release checks build the crates before deployment, so the build
# below reuses their store outputs when the inputs match.
# It runs as libri-deploy.service (libri-deploy.mod.nix beside it), on a
# checkout of the pushed commit it deploys: started from inside libri.service,
# the restart below would kill it before its health check. It logs to the file
# below. It lives in monix, not in Libri: Libri holds the product only.
LOG=${DEPLOY_LIBRI_LOG:-/tmp/deploy_libri.log}
# Keep the current build linked until the new build passes the core check.
LINK=${DEPLOY_LIBRI_LINK:-/var/lib/libri-build/libri}
STAGE=$LINK.next
# Each instance's unit and port. Suki's hippo is her daemon's child, as on
# any install; the seat's is a unit of its own, as it keeps the cockpit's
# chats too.
INSTANCES=${DEPLOY_LIBRI_INSTANCES:-libri:8951 suki:8952}
HIPPOS=${DEPLOY_LIBRI_HIPPOS:-hippo}

exec > "$LOG" 2>&1
cd "${1:?usage: deploy_libri.sh CHECKOUT}" || exit 1
echo "deploying $(git rev-parse --short HEAD) $(date +%T)"
previous=$(readlink "$LINK")
nix build .#default -o "$STAGE" || { echo "build failed, not deployed"; exit 1; }
built=$(readlink "$STAGE")
echo "built $built"
if [ -x "$LINK/bin/libri-core" ] && [ ! -x "$STAGE/bin/libri-core" ]; then
  echo "build has no libri-core, not deployed"
  rm -f "$STAGE"
  exit 1
fi

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
restart_core() {
  if [ -x "$LINK/bin/libri-core" ]; then
    # The unit's post-start check waits for the new daemon's owner socket.
    systemctl restart libri-core.service
  elif [ -x "$built/bin/libri-core" ]; then
    # A rollback to a release before the core was packaged.
    systemctl stop libri-core.service
  fi
}

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
if restart_core; then
  restart
  if answers; then
    echo "live $(date +%T)"
    exit 0
  fi
else
  echo "libri-core did not answer"
fi
echo "new build did not answer; back to $previous"
if nix build "$previous" -o "$LINK"; then
  restart_core || echo "could not restore libri-core"
  restart
fi
exit 1
