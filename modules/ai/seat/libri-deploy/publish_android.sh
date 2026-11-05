#!/usr/bin/env bash
# Publishes a signed Libri APK at libri.is/android/ for phones and Obtainium:
# it adds the APK to the release folder, then starts libri-publish.service,
# which uploads the folder to the libri.is Worker.
# Each release stays as libri-<versionName>.apk, listed newest first on
# index.html. Obtainium's HTML source reads the version from the newest file's
# name, so a check offers an update only when there is one; one bare libri.apk
# gave it nothing to read and it offered the same build forever. libri.apk
# stays as a link to the newest for old links. The index doesn't link it:
# "libri.apk" sorts after every "libri-<v>.apk", so Obtainium would take it.
# Refuses an APK signed by another key, which phones would refuse to update to.
# Runs from a Libri checkout, for its Android dev shell; on the seat's PATH as
# libri-publish-android.
# Usage: libri-publish-android path/to/release.apk [LIBRI_CHECKOUT]
set -euo pipefail
apk=$(realpath "$1")
D=${LIBRI_ANDROID_DIR:-/var/lib/libri-android}
cd "${2:-.}"
[ -f android/settings.gradle.kts ] || { echo "not a Libri checkout: $(pwd)"; exit 1; }

# awk, not head: head exits early and pipefail turns the writer's SIGPIPE
# into a failure.
facts=$(nix develop .#android --command bash -c '
  set -euo pipefail
  aapt=$(find -L "$ANDROID_SDK_ROOT" -name aapt2 | sort | tail -n1)
  signer=$(find -L "$ANDROID_SDK_ROOT" -name apksigner | sort | tail -n1)
  cert() { "$signer" verify --print-certs "$1" | awk "/SHA-256 digest/ && !n++ {print \$NF}"; }
  "$aapt" dump badging "$1" | awk -F"'"'"'" "NR==1 {print \$6}"
  cert "$1"
  if [ -e "$2/libri.apk" ]; then cert "$2/libri.apk"; else echo none; fi
' publish "$apk" "$D")
{ read -r version; read -r new; read -r old; } <<<"$facts"
[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "unreadable versionName '$version'"; exit 1; }
[ -n "$new" ] && { [ "$old" = none ] || [ "$new" = "$old" ]; } ||
  { echo "certificate $new is not the published $old; not published"; exit 1; }

name=libri-$version.apk
if [ -e "$D/$name" ]; then
  # A version names one build: phones that have it would never take another.
  cmp -s "$apk" "$D/$name" || { echo "$name is already published with other bytes; bump the version"; exit 1; }
else
  install -p -m 644 "$apk" "$D/.$name" && mv "$D/.$name" "$D/$name"
fi

newest=$(cd "$D" && ls libri-*.apk | sort -V | tail -n1)
ln -sfn "$newest" "$D/.libri.apk" && mv -T "$D/.libri.apk" "$D/libri.apk"

{
  printf '<!doctype html>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width">\n'
  printf '<title>Libri for Android</title>\n<h1>Libri for Android</h1>\n<ul>\n'
  (cd "$D" && ls libri-*.apk | sort -rV) | while read -r f; do
    printf '<li><a href="%s">%s</a> %s, sha256 %s</li>\n' "$f" "$f" \
      "$(date -r "$D/$f" +%F)" "$(sha256sum "$D/$f" | cut -c1-16)"
  done
  printf '</ul>\n'
} > "$D/.index.html"
chmod 644 "$D/.index.html" && mv "$D/.index.html" "$D/index.html"
echo "published $name; libri.apk is $newest"
systemctl start --no-block libri-publish.service
echo "libri.is/android/ updates when libri-publish.service finishes (journalctl -u libri-publish)"
