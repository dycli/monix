#!/usr/bin/env bash
# Lists where Libri's phone web and Android app drift apart in what changed
# since a release tag. The two must match; each change lands on both or says
# why not. Parity is kept by quick follow-up, not by holding a release, so
# this reports and never fails the release that runs it.
#
# Two passes. The first is plain git: every commit since the tag that touches
# the web page's code or the Android app's code but not the other. The second
# hands those commits to stock Claude Code (`claude -p`, read-only tools in
# the checkout) to say which of them leave a real difference a person would
# notice, since many one-sided commits are fine: a wide-screen-only change,
# a fix to code only one side has, or the other side already done before.
#
# Prints markdown on stdout. On the seat's PATH as libri-parity.
# Usage: libri-parity SINCE_TAG [LIBRI_CHECKOUT]
set -uo pipefail
since=$1
cd "${2:-$HOME/ark/libri}" || exit 1
web=libri/site/src
android=android/app/src/main

one_sided=()
while read -r commit; do
  files=$(git show --name-only --format= "$commit")
  w=$(grep -c "^$web/" <<< "$files")
  a=$(grep -c "^$android/" <<< "$files")
  if ((w > 0 && a == 0)); then
    one_sided+=("$commit web-only $(git log -1 --format=%s "$commit")")
  elif ((a > 0 && w == 0)); then
    one_sided+=("$commit android-only $(git log -1 --format=%s "$commit")")
  fi
done < <(git rev-list --no-merges --reverse "$since..HEAD")

echo "### Web and Android parity since $since"
echo
if ((${#one_sided[@]} == 0)); then
  echo "Every change to either app since $since touched both."
  exit 0
fi
echo "Commits that change one app only:"
echo
for line in "${one_sided[@]}"; do
  read -r commit side subject <<< "$line"
  echo "- \`${commit:0:7}\` ($side) $subject"
done
echo

# The model's read of those commits. Read-only tools: it looks at the other
# app's code to see whether the behaviour is already there.
prompt="You are checking feature parity between two clients of one product,
Libri, in this repository. The phone web layout ($web, phone.tsx and what it
uses, widths under 600px) and the Android app ($android) must behave and look
the same. The wide desktop web layout has no Android counterpart; a change
only to it is not a mismatch.

These commits since $since change one client only:
$(printf '%s\n' "${one_sided[@]}")

For each, read its diff (git show COMMIT) and the other client's matching
code. List only real mismatches a person on the phone would notice: behaviour,
layout, wording or a missing feature that one client has and the other
lacks. For each mismatch give one line: the commit, which client lacks what,
and the file on the lacking side to change. Skip commits that need nothing.
If nothing mismatches, answer exactly: No mismatches found.
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
exit 0
