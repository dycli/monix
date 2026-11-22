#!/bin/sh
# Starts UI latency for a released Libri version (libri-ui-latency@VERSION,
# ordered after a deploy under way) and returns.
# On the seat's PATH as libri-start-ui-latency.
# Usage: libri-start-ui-latency VERSION
set -eu
case ${1:-} in
'' | *[!0-9.]*) echo "usage: libri-start-ui-latency VERSION" >&2; exit 2 ;;
esac
exec systemctl start --no-block "libri-ui-latency@$1.service"
