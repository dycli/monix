#!/bin/sh
# Usage: publish_libri_sites.sh
# Publishes Libri's two Cloudflare Workers from what Water has live, so
# neither goes stale:
# - libri.is (libri-is-site): its pages, plus every Android release in
#   ANDROID_DIR at /android/, with the listing and libri.apk, the newest.
# - app.libri.is (libri-app): the seat's live site build at SITE.
# Runs as libri-publish.service, after each Libri deploy and each Android
# publish; the Cloudflare token arrives as a systemd credential and never
# reaches the seat or its workers.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ANDROID_DIR=${LIBRI_ANDROID_DIR:-/var/lib/libri-android}
SITE=${LIBRI_PUBLISH_SITE:-/var/lib/libri-build/libri/site}
WORK=${LIBRI_PUBLISH_DIR:?LIBRI_PUBLISH_DIR names the staging folder}
TOKEN_FILE=${LIBRI_PUBLISH_TOKEN:-${CREDENTIALS_DIRECTORY:-/nonexistent}/cloudflare}
: "${CLOUDFLARE_ACCOUNT_ID:?}"
CLOUDFLARE_API_TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
export CLOUDFLARE_API_TOKEN WRANGLER_SEND_METRICS=false

# Each Worker is staged afresh: its config and script, then its assets.
stage() {
  rm -rf "${WORK:?}/$1"
  mkdir -p "$WORK/$1"
  cp "$here/$1"/* "$WORK/$1/"
  chmod -R u+w "$WORK/$1"
}

stage libri-is
mkdir -p "$WORK/libri-is/assets/android"
mv "$WORK/libri-is/_headers" "$WORK/libri-is/assets/_headers"
# Assets hold no links: libri.apk becomes a copy of the newest, which the
# upload stores once, as files are kept by their hash.
cp -L "$ANDROID_DIR"/index.html "$ANDROID_DIR"/libri-*.apk "$ANDROID_DIR"/libri.apk \
  "$WORK/libri-is/assets/android/"
(cd "$WORK/libri-is" && wrangler deploy)

stage libri-app
cp -rL "$SITE" "$WORK/libri-app/site"
chmod -R u+w "$WORK/libri-app/site"
mv "$WORK/libri-app/_headers" "$WORK/libri-app/site/_headers"
# The daemon serves its manifest itself (site.rs); the hosted copy needs a
# file. Removed once the site build carries public/manifest.webmanifest
# (Libri's hosted-app branch).
[ -e "$WORK/libri-app/site/manifest.webmanifest" ] ||
  cp "$WORK/libri-app/manifest.webmanifest" "$WORK/libri-app/site/"
rm -f "$WORK/libri-app/manifest.webmanifest"
(cd "$WORK/libri-app" && wrangler deploy)
echo "published libri.is ($(readlink "$ANDROID_DIR/libri.apk")) and app.libri.is ($(readlink -f "$SITE"))"
