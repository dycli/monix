#!/bin/sh
# Starts the deploy of pushed Libri main (libri-deploy.service), naming the
# worker that starts it so its own run doesn't hold the deploy's quiet wait.
# A worker passes its name, as the Work page shows it; Bridge passes none.
# On the seat's PATH as libri-start-deploy.
# Usage: libri-start-deploy [WORKER]
set -eu
if [ -n "${1:-}" ]; then
  printf '%s\n' "$1" > "${DEPLOY_LIBRI_STARTER:-/var/lib/libri-deploy/starter}"
fi
exec systemctl start --no-block libri-deploy.service
