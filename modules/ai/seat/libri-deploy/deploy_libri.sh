#!/bin/sh
# Usage: deploy_libri.sh CHECKOUT
# Deploys the Libri commit checked out at CHECKOUT on Water to all configured
# Stage 2 cores, gateways, and add-ons, plus any legacy instances (Suki).
# Interrupted turns resume after the restart.
# The release checks build the crates before deployment, so the build
# below reuses their store outputs when the inputs match.
# It runs as libri-deploy.service (libri-deploy.mod.nix beside it), on a
# checkout of the pushed commit it deploys: started from inside a core,
# the restart below would kill it before its health check. It logs to the file
# below. It lives in monix, not in Libri: Libri holds the product only.
LOG=${DEPLOY_LIBRI_LOG:-/tmp/deploy_libri.log}
# Keep the current build linked until the new build passes the core check.
LINK=${DEPLOY_LIBRI_LINK:-/var/lib/libri-build/libri}
STAGE=$LINK.next
ADDONS_DIR=${DEPLOY_LIBRI_ADDONS_DIR:-/var/lib/libri-build/addons}
ADDONS=${DEPLOY_LIBRI_ADDONS:-}
# Space-separated served add-on entries: either `addon` (shorthand for
# `libri-addon-$addon:$addon`) or `unit:addon` (for multi-assistant hosts).
SERVED_ADDONS=${DEPLOY_LIBRI_SERVED_ADDONS:-}
# Space-separated Stage 2 core service names (without `.service`).
CORES=${DEPLOY_LIBRI_CORES-libri-core}
# Space-separated Stage 2 gateway `unit:port` pairs (without `.service`).
# Falls back to single `libri-gateway:$DEPLOY_LIBRI_GATEWAY_PORT` when unset.
GATEWAY_PORT=${DEPLOY_LIBRI_GATEWAY_PORT:-}
if [ -n "${DEPLOY_LIBRI_GATEWAYS+x}" ]; then
  GATEWAYS=$DEPLOY_LIBRI_GATEWAYS
elif [ -n "$GATEWAY_PORT" ]; then
  GATEWAYS="libri-gateway:$GATEWAY_PORT"
else
  GATEWAYS=
fi
# Each legacy instance's unit and port. Suki's hippo is her daemon's child, as
# on any install; the seat's is a unit of its own when enabled.
INSTANCES=${DEPLOY_LIBRI_INSTANCES-libri:8951 suki:8952}
HIPPOS=${DEPLOY_LIBRI_HIPPOS-hippo}

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
# Each served add-on unit tracks its last started binary under $ADDONS_DIR so
# only units whose add-on binary changed restart. `libri-addon-$a` keeps its
# legacy `.$a.ran` name; any other assistant's unit uses `.$unit.ran`.
tried_addons=
restart_addons() {
  for spec in $SERVED_ADDONS; do
    case "$spec" in
      *:*)
        unit=${spec%%:*}
        a=${spec#*:}
        ;;
      *)
        unit="libri-addon-$spec"
        a=$spec
        ;;
    esac
    bin="$ADDONS_DIR/$a/bin/libri-$a"
    if [ "$unit" = "libri-addon-$a" ]; then
      ran="$ADDONS_DIR/.$a.ran"
    else
      ran="$ADDONS_DIR/.$unit.ran"
    fi
    if [ -x "$bin" ]; then
      target=$(readlink -f "$bin")
      needs_restart=
      if [ "$(cat "$ran" 2>/dev/null)" != "$target" ]; then
        needs_restart=1
      else
        case " $tried_addons " in *" $unit "*) needs_restart=1 ;; esac
      fi
      if [ -n "$needs_restart" ]; then
        tried_addons="$tried_addons $unit"
        if systemctl restart "$unit.service"; then
          echo "$target" > "$ran"
        else
          echo "$unit did not restart"
        fi
      fi
    elif systemctl is-active -q "$unit.service"; then
      systemctl stop "$unit.service" || echo "$unit did not stop"
      rm -f "$ran"
    fi
  done
}

had_gateways=
had_legacy_gateway=
restart_core() {
  if [ -x "$LINK/bin/libri-core" ]; then
    # Each core unit's post-start check waits for its owner socket.
    for c in $CORES; do
      systemctl restart "$c.service" || return 1
    done
    restart_addons
    # Each configured gateway runs the same build. One not running stays off:
    # it waits for its credential, and a host without it has no such unit.
    if [ -n "$GATEWAYS" ]; then
      for g in $GATEWAYS; do
        g_unit=${g%%:*}
        case " $had_gateways " in
          *" $g_unit "*)
            systemctl restart "$g_unit.service" || return 1
            ;;
          *)
            if systemctl is-active -q "$g_unit.service"; then
              had_gateways="$had_gateways $g_unit"
              systemctl restart "$g_unit.service" || return 1
            fi
            ;;
        esac
      done
    elif [ -n "$had_legacy_gateway" ] || systemctl is-active -q libri-gateway.service; then
      had_legacy_gateway=1
      systemctl restart libri-gateway.service || echo "libri-gateway did not restart"
    fi
  elif [ -x "$built/bin/libri-core" ]; then
    # A rollback to a release before the core was packaged.
    for c in $CORES; do
      systemctl stop "$c.service"
    done
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
# Whether every active configured gateway and legacy instance answers within 30 seconds.
answers() {
  for g in $GATEWAYS; do
    g_unit=${g%%:*}
    g_port=${g##*:}
    case " $had_gateways " in
      *" $g_unit "*)
        gw="http://127.0.0.1:$g_port/"
        up=
        for _ in $(seq 30); do
          if [ "$(curl -s -m3 -o /dev/null -w '%{http_code}' "$gw")" = "200" ]; then
            up=1
            break
          fi
          sleep 1
        done
        [ -n "$up" ] || { echo "$g_unit did not answer"; return 1; }
        ;;
    esac
  done
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
