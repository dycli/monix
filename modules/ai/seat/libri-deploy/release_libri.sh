#!/usr/bin/env bash
# Releases Libri from a checkout of main, the one way a release happens:
# runs the checks for the release's scope, bumps the version, builds the
# signed APK, commits, tags and pushes, publishes the APK, then starts the
# Water deploy and UI latency after it. Any failure stops it there, with
# nothing pushed if the failure comes before the push; a failing check is
# fixed, not rerun.
#
# Parity between the phone web and the Android app, and between the wide web
# and the desktop app, is reported, not enforced:
# a release goes out with a known gap and the next one closes it, as
# Superlogical keeps parity by quick follow-up rather than by holding work.
# The report and the changelog entry make the release notes, written to
# ~/.local/state/libri-release/VERSION.md and printed at the end for Bridge
# to pass on; the app shows the changelog entry itself as What's new.
#
# The changelog entry for the new version may be written by hand beforehand,
# left uncommitted in libri/CHANGELOG.md; without one, set_version.sh drafts
# it from the commit subjects since the last tag.
#
# The deploy runs in its own unit. Its result is in /var/lib/libri-deploy/status.
# It doesn't move monix's Libri pin, which carries only the NixOS module; the
# routine flake update moves it.
#
# UI latency (Libri's 400 ms check) runs after the deploy, in a unit of its
# own, and reports a miss rather than holding the release, as Chromium
# measures performance after landing instead of gating on it: on the
# release's path it took 1974 s for 0.9.116, and 1104 s run in parallel.
# Its result is in /var/lib/libri-deploy/ui-latency.status.
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

last=$(git describe --tags --abbrev=0 --match 'v*' HEAD)
core_only=
# A checkout that predates the scope query stays on the full release gate.
if scope=$(./check_changes.sh --core-only "$last" 2>/dev/null) && [[ $scope == core-only ]]; then
  core_only=1
  # Check the committed delta before the release adds the daemon version bump.
  step "core checks"
  if ! nice -n 10 ./check_changes.sh "$last" -- -L > /tmp/libri-release-checks.log 2>&1; then
    grep -E "FAIL|error:" /tmp/libri-release-checks.log | head -20 || true
    echo "core checks failed (log /tmp/libri-release-checks.log): fix, don't rerun"
    exit 1
  fi
  echo "core checks pass"
fi

# The slow checks (browser checks, UI latency) whose inputs changed since
# the last release, which ran them: one whose inputs did not would run
# the same test on the same build again. Libri's check_changes.sh reads the
# inputs from its flake; a checkout that predates the query, or a query
# that fails, runs both.
if ! grep -q -- '--release-checks' check_changes.sh || ! slow=$(./check_changes.sh --release-checks "$last"); then
  slow=$'browser-checks\nui-latency'
fi
needs() { grep -qx "$1" <<< "$slow"; }

# Puts the version files back if anything below fails before the commit.
undo() { git checkout --quiet -- libri/Cargo.toml libri/Cargo.lock; }
trap undo ERR

# Locks: the browser checks and the gate take Libri's timing lock themselves
# (its nix/with_check_lock.sh), one timing run at a time with no build beside
# it; the flake check is a build and runs beside others'.
step "version"
./set_version.sh "$version"

if [[ -n $core_only ]]; then
  echo "Skipping the flake, browser and UI latency checks: only core and documentation changed since $last."
else
  step "checks"
  if ! nice -n 10 nix/with_check_lock.sh --build nix flake check -L > /tmp/libri-release-checks.log 2>&1; then
    grep -E "FAIL|error:" /tmp/libri-release-checks.log | head -20
    echo "checks failed (log /tmp/libri-release-checks.log): fix, don't rerun"
    false
  fi
  echo "checks pass"

  step "browser checks"
  # The Playwright runs of the built page, which the build sandbox can't hold.
  shots=/tmp/libri-release-shots-$version
  if ! needs browser-checks; then
    echo "browser checks SKIPPED: nothing they run changed since $last"
  elif ! nice -n 10 nix run .#browser-checks -- "$shots" > /tmp/libri-release-browser.log 2>&1; then
    grep -E "^(FAIL|== .* FAILED)" /tmp/libri-release-browser.log | head -20
    echo "browser checks failed (log /tmp/libri-release-browser.log, pictures $shots): fix, don't rerun"
    false
  else
    echo "browser checks pass"
  fi
fi

step "android checks"
# The Android app's emulator drives (drive_android_*.py in the Libri
# checkout) belong here, stopping the release as the browser checks do. Water
# can't hold an emulator beside its load on 30 GiB; this step runs them once
# its 96 GiB is in.
echo "not run: the emulator waits for Water's memory"

step "parity"
# It never stops the release; a failed review says so in the notes.
parity=$(libri-parity "$last" .) || parity="### Client parity since $last

The parity review failed to run."
echo "$parity"

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

step "notes"
notes=${XDG_STATE_HOME:-$HOME/.local/state}/libri-release/$version.md
mkdir -p "$(dirname "$notes")"
{
  echo "# Libri $version"
  echo
  awk -v head="## $version " 'index($0, head) == 1 { on = 1; next } on && /^## / { exit } on' libri/CHANGELOG.md
  echo "$parity"
} > "$notes"
cat "$notes"

step "deploy"
libri-start-deploy

step "ui latency"
# Queued behind the deploy (its unit is ordered after libri-deploy.service),
# so its timing doesn't share the host with the deploy's build and restart.
if [[ -n $core_only ]]; then
  latency="UI latency not run: only core and documentation changed since $last"
elif ! needs ui-latency; then
  latency="UI latency not run: neither the page, its tiles nor the check changed since $last"
elif libri-start-ui-latency "$version"; then
  latency="UI latency runs after the deploy, result in /var/lib/libri-deploy/ui-latency.status"
else
  latency="UI latency did not start: run libri-start-ui-latency $version"
fi
echo "$latency"
echo "Libri $version released: APK published; Water deploy requested, result in /var/lib/libri-deploy/status; $latency; notes in $notes"
