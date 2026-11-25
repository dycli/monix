#!/bin/sh
# Usage: deploy_libri.sh CHECKOUT
# Deploys the Libri commit checked out at CHECKOUT on Water to Libri, Suki,
# the core daemon, and its enabled add-ons. Interrupted turns resume after the
# restart.
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
ADDONS_DIR=${DEPLOY_LIBRI_ADDONS_DIR:-/var/lib/libri-build/addons}
ADDONS=${DEPLOY_LIBRI_ADDONS:-}
SERVED_ADDONS=${DEPLOY_LIBRI_SERVED_ADDONS:-}
# Each instance's unit and port. Suki's hippo is her daemon's child, as on
# any install; the seat's is a unit of its own when enabled.
INSTANCES=${DEPLOY_LIBRI_INSTANCES-libri:8951 suki:8952}
HIPPOS=${DEPLOY_LIBRI_HIPPOS-hippo}
GATEWAY_PORT=${DEPLOY_LIBRI_GATEWAY_PORT:-}

exec > "$LOG" 2>&1
cd "${1:?usage: deploy_libri.sh CHECKOUT}" || exit 1
echo "deploying $(git rev-parse --short HEAD) $(date +%T)"

cleanup_staged() {
  rm -f "$STAGE"
  for a in $ADDONS; do
    rm -f "$ADDONS_DIR/$a.next"
  done
}

previous=$(readlink "$LINK")
nix build .#default -o "$STAGE" || { echo "build failed, not deployed"; exit 1; }
built=$(readlink "$STAGE")
echo "built $built"
if [ -x "$LINK/bin/libri-core" ] && [ ! -x "$STAGE/bin/libri-core" ]; then
  echo "build has no libri-core, not deployed"
  rm -f "$STAGE"
  exit 1
fi

prev_addons_dir=
if [ -n "$ADDONS" ]; then
  mkdir -p "$ADDONS_DIR" || { echo "cannot create $ADDONS_DIR, not deployed"; cleanup_staged; exit 1; }
  for a in $ADDONS; do
    nix build ".#$a" -o "$ADDONS_DIR/$a.next" || {
      echo "addon $a build failed, not deployed"
      cleanup_staged
      exit 1
    }
    echo "built addon $a $(readlink "$ADDONS_DIR/$a.next")"
  done
  prev_addons_dir=$(mktemp -d) || { echo "cannot create temp dir, not deployed"; cleanup_staged; exit 1; }
  trap 'rm -rf "$prev_addons_dir"' EXIT
  for a in $ADDONS; do
    if [ -L "$ADDONS_DIR/$a" ]; then
      readlink "$ADDONS_DIR/$a" > "$prev_addons_dir/$a"
    fi
  done
fi

moved_addons=
restore_addons() {
  for a in $moved_addons; do
    if [ -n "$prev_addons_dir" ] && [ -f "$prev_addons_dir/$a" ]; then
      prev=$(cat "$prev_addons_dir/$a")
      nix build "$prev" -o "$ADDONS_DIR/$a" || echo "could not restore addon $a"
    else
      rm -f "$ADDONS_DIR/$a"
    fi
  done
}

# nix build, not ln, so the link is a GC root on a host this script never
# deployed to before.
nix build "$built" -o "$LINK" || { echo "link not moved, not deployed"; cleanup_staged; exit 1; }
rm -f "$STAGE"

for a in $ADDONS; do
  addon_built=$(readlink "$ADDONS_DIR/$a.next")
  if ! nix build "$addon_built" -o "$ADDONS_DIR/$a"; then
    echo "addon $a link not moved, not deployed"
    cleanup_staged
    restore_addons
    nix build "$previous" -o "$LINK" || echo "could not restore $LINK"
    exit 1
  fi
  rm -f "$ADDONS_DIR/$a.next"
  moved_addons="$moved_addons $a"
done

echo "restarting $(date +%T)"
# A hippo unit runs from the same build; its store outlives any restart, and
# Libri waits for it, so it restarts only when the binary changed.
# HIPPO_RAN names the binary the last restart started, not the link's old
# target: a deploy killed after moving the link would leave old and new the
# same, and the rerun would leave the old hippo running.
HIPPO_RAN=$LINK.hippo
# Each served add-on tracks its last started binary in $ADDONS_DIR/.$name.ran
# the same way, so only add-ons whose binary changed restart.
tried_addons=
restart_addons() {
  for a in $SERVED_ADDONS; do
    bin="$ADDONS_DIR/$a/bin/libri-$a"
    ran="$ADDONS_DIR/.$a.ran"
    if [ -x "$bin" ]; then
      target=$(readlink -f "$bin")
      needs_restart=
      if [ "$(cat "$ran" 2>/dev/null)" != "$target" ]; then
        needs_restart=1
      else
        case " $tried_addons " in *" $a "*) needs_restart=1 ;; esac
      fi
      if [ -n "$needs_restart" ]; then
        tried_addons="$tried_addons $a"
        if systemctl restart "libri-addon-$a.service"; then
          echo "$target" > "$ran"
        else
          echo "libri-addon-$a did not restart"
        fi
      fi
    elif systemctl is-active -q "libri-addon-$a.service"; then
      systemctl stop "libri-addon-$a.service" || echo "libri-addon-$a did not stop"
      rm -f "$ran"
    fi
  done
}

had_gateway=
restart_core() {
  if [ -x "$LINK/bin/libri-core" ]; then
    # The unit's post-start check waits for the new daemon's owner socket.
    systemctl restart libri-core.service || return 1
    restart_addons
    # The gateway runs the same build. One not running stays off: it waits
    # for its credential, and a host without it has no such unit. When
    # GATEWAY_PORT is set, a restart failure rolls the deploy back.
    if [ -n "$had_gateway" ] || systemctl is-active -q libri-gateway.service; then
      had_gateway=1
      if [ -n "$GATEWAY_PORT" ]; then
        systemctl restart libri-gateway.service || return 1
      else
        systemctl restart libri-gateway.service || echo "libri-gateway did not restart"
      fi
    fi
  elif [ -x "$built/bin/libri-core" ]; then
    # A rollback to a release before the core was packaged.
    systemctl stop libri-core.service
  fi
}

restart() {
  if [ -n "$HIPPOS" ]; then
    hippo=$(readlink -f "$LINK/bin/hippo")
    if [ "$(cat "$HIPPO_RAN" 2>/dev/null)" != "$hippo" ]; then
      ok=1
      for h in $HIPPOS; do
        systemctl restart "$h.service" || ok=
      done
      [ -z "$ok" ] || echo "$hippo" > "$HIPPO_RAN"
    fi
  fi
  for i in $INSTANCES; do
    systemctl restart "${i%%:*}.service"
  done
}
# Whether the gateway (when configured and active) and every instance answer within 30 seconds.
answers() {
  if [ -n "$GATEWAY_PORT" ] && [ -n "$had_gateway" ]; then
    gw="http://127.0.0.1:$GATEWAY_PORT/"
    up=
    for _ in $(seq 30); do
      if [ "$(curl -s -m3 -o /dev/null -w '%{http_code}' "$gw")" = "200" ]; then
        up=1
        break
      fi
      sleep 1
    done
    [ -n "$up" ] || { echo "libri-gateway did not answer"; return 1; }
  fi
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
restore_addons
if nix build "$previous" -o "$LINK"; then
  restart_core || echo "could not restore libri-core"
  restart
fi
exit 1
