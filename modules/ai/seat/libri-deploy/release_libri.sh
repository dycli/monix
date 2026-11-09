#!/usr/bin/env bash
# Releases Libri from a checkout of main, the one way a release happens:
# bumps the version, runs the full flake check, builds the signed APK,
# commits, tags and pushes, publishes the APK, then starts the Water deploy.
# Any failure stops it there, with nothing pushed if the failure comes before
# the push; a failing check is fixed, not rerun.
#
# The changelog entry for the new version may be written by hand beforehand,
# left uncommitted in libri/CHANGELOG.md; without one, set_version.sh drafts
# it from the commit subjects since the last tag.
#
# The deploy waits for Libri to be quiet, so started from a Libri turn it goes
# live once that turn ends; its result is in /var/lib/libri-deploy/status.
# It doesn't move monix's Libri pin, which carries only the NixOS module and
# the `tell` command; the routine flake update moves it.
#
# On the seat's PATH as libri-release.
# Usage: libri-release [VERSION] [LIBRI_CHECKOUT]   (default: next patch, ~/ark/libri)
set -euo pipefail
cd "${2:-$HOME/ark/libri}"
step() { printf '\n== %s\n' "$*"; }

step "checkout"
git fetch --quiet origin
[[ $(git branch --show-current) == main ]] || { echo "not on main"; exit 1; }
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] ||
  { echo "main differs from origin/main: merge first"; exit 1; }
dirty=$(git status --porcelain | grep -v ' libri/CHANGELOG.md$' || true)
[[ -z $dirty ]] || { echo "uncommitted changes besides the changelog:"; echo "$dirty"; exit 1; }

current=$(sed -n '0,/^version = /s/^version = "\(.*\)"/\1/p' libri/Cargo.toml)
version=${1:-${current%.*}.$((${current##*.} + 1))}
echo "$current -> $version"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && { echo "v$version is already tagged"; exit 1; }

# Puts the version files back if anything below fails before the commit.
undo() { git checkout --quiet -- libri/Cargo.toml libri/Cargo.lock; }
trap undo ERR

step "version"
./set_version.sh "$version"

step "checks"
if ! nice -n 10 nix flake check -L > /tmp/libri-release-checks.log 2>&1; then
  grep -E "FAIL|error:" /tmp/libri-release-checks.log | head -20
  echo "checks failed (log /tmp/libri-release-checks.log): fix, don't rerun"
  false
fi
echo "checks pass"

step "android"
nice -n 10 ./build_android_release.sh

step "push"
git commit --quiet -am "Release $version"
trap - ERR
git tag "v$version"
git push --quiet origin main "v$version"
echo "pushed $(git rev-parse --short HEAD) v$version"

step "publish"
libri-publish-android "${LIBRI_ANDROID_KEYS:-${XDG_DATA_HOME:-$HOME/.local/share}/libri-android}/libri-$version.apk" .

step "deploy"
libri-start-deploy
echo "Libri $version released: APK published; Water deploy queued for the next quiet moment, result in /var/lib/libri-deploy/status"
