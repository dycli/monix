#!/usr/bin/env bash
# Lists where Libri's clients drift apart in what changed since a release
# tag. Two pairs must match: the phone web and the Android app, and the wide
# web and the native desktop app. Each change lands on both sides of its pair
# or says why not. Parity is kept by quick follow-up, not by holding a
# release, so this reports and never fails the release that runs it.
#
# For each pair, two passes. The first is plain git: every commit since the
# tag that touches one side's code but not the other's. The second hands
# those commits to stock Claude Code (`claude -p`, read-only tools in the
# checkout) to say which of them leave a real difference a person would
# notice, since many one-sided commits are fine: a change only the other
# layout shows, a fix to code only one side has, or the other side already
# done before.
#
# A pair whose side is not in the checkout yet (the desktop app before it
# lands on main), or not yet at the tag (the release it lands in, when every
# commit of it would read as one-sided), is left out, and the report says so.
#
# Prints markdown on stdout. On the seat's PATH as libri-parity.
# Usage: libri-parity SINCE_TAG [LIBRI_CHECKOUT]
set -uo pipefail
since=$1
cd "${2:-$HOME/ark/libri}" || exit 1
web=web/src
[[ -d $web ]] || web=libri/site/src
android=android/app/src/main
desktop=desktop/src

# review TITLE A_NAME A_PATH B_NAME B_PATH SCOPE: one pair's section. SCOPE
# tells the model which part of each side is meant to match.
review() {
  local title=$1 a_name=$2 a_path=$3 b_name=$4 b_path=$5 scope=$6
  local one_sided=() commit files a b line side subject findings
  while read -r commit; do
    files=$(git show --name-only --format= "$commit")
    a=$(grep -c "^$a_path/" <<< "$files")
    b=$(grep -c "^$b_path/" <<< "$files")
    if ((a > 0 && b == 0)); then
      one_sided+=("$commit $a_name-only $(git log -1 --format=%s "$commit")")
    elif ((b > 0 && a == 0)); then
      one_sided+=("$commit $b_name-only $(git log -1 --format=%s "$commit")")
    fi
  done < <(git rev-list --no-merges --reverse "$since..HEAD")

  echo "#### $title"
  echo
  if ((${#one_sided[@]} == 0)); then
    echo "Every change to either side since $since touched both."
    echo
    return
  fi
  echo "Commits that change one side only:"
  echo
  for line in "${one_sided[@]}"; do
    read -r commit side subject <<< "$line"
    echo "- \`${commit:0:7}\` ($side) $subject"
  done
  echo

  # The model's read of those commits. Read-only tools: it looks at the
  # other side's code to see whether the behaviour is already there.
  local prompt
  prompt="You are checking feature parity between two clients of one
product, Libri, in this repository. $scope

These commits since $since change one client only:
$(printf '%s\n' "${one_sided[@]}")

For each, read its diff (git show COMMIT) and the other client's matching
code. List only real mismatches a person would notice: behaviour, layout,
wording or a missing feature that one client has and the other lacks. For
each mismatch give one line: the commit, which client lacks what, and the
file on the lacking side to change. Skip commits that need nothing. If
nothing mismatches, answer exactly: No mismatches found.
Answer as a markdown list with no preamble."

  if findings=$(timeout 1200 claude -p --model "${LIBRI_REVIEW_MODEL:-claude-opus-5-5}" \
    --allowedTools "Read,Grep,Glob,Bash(git show:*),Bash(git log:*),Bash(git diff:*)" \
    <<< "$prompt" 2>&1); then
    echo "Claude's read of them:"
    echo
    echo "$findings"
  else
    echo "The model review did not finish (claude -p exit $?); the list above is unreviewed."
  fi
  echo
}

echo "### Client parity since $since"
echo
review "Phone web and Android" web "$web" android "$android" \
  "The phone web layout ($web, phone.tsx and what it uses, widths under
600px) and the Android app ($android) must behave and look the same. The wide
web layout has no Android counterpart; a change only to it is not a mismatch."
if [[ ! -d $desktop ]]; then
  echo "#### Wide web and desktop"
  echo
  echo "Not checked: this checkout has no $desktop yet."
  echo
elif ! git cat-file -e "$since:$desktop" 2> /dev/null; then
  echo "#### Wide web and desktop"
  echo
  echo "Not checked: the desktop app is new since $since; the next release compares it."
  echo
else
  review "Wide web and desktop" web "$web" desktop "$desktop" \
    "The wide web layout ($web, widths of 600px and over) and the native
desktop app ($desktop, Rust with the Rune toolkit, its shared logic in client/src)
must behave and look the same. The phone web layout has no desktop
counterpart; a change only to it is not a mismatch. A change only the
browser can make (a service worker, a browser permission) is not one either."
fi
exit 0
