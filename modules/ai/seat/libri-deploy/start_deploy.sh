#!/bin/sh
# Starts the deploy of pushed Libri main (libri-deploy.service) and returns.
# On the seat's PATH as libri-start-deploy.
set -eu
exec systemctl start --no-block libri-deploy.service
