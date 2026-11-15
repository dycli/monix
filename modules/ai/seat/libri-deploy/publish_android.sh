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
# Also renders the checkout's docs/privacy.md to privacy.html beside the
# APKs, which libri.is serves at /privacy, the address the store listings
# give: the policy published is the one the release was built with.
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

if [ -f docs/privacy.md ]; then
  {
    printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    printf '<meta http-equiv="Content-Security-Policy" content="default-src '"'none'; style-src 'unsafe-inline'"'">\n'
    printf '<title>Libri for Android: privacy policy</title>\n<style>\n'
    printf '  :root { color-scheme: light dark; }\n'
    printf '  body { font: 17px/1.55 system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; padding: 0 1.25rem; }\n'
    printf '</style>\n</head>\n<body>\n'
    cmark docs/privacy.md
    printf '</body>\n</html>\n'
  } > "$D/.privacy.html"
  chmod 644 "$D/.privacy.html" && mv "$D/.privacy.html" "$D/privacy.html"
  echo "privacy.html rendered from docs/privacy.md"
fi
echo "published $name; libri.apk is $newest"
systemctl start --no-block libri-publish.service
echo "libri.is/android/ updates when libri-publish.service finishes (journalctl -u libri-publish)"
