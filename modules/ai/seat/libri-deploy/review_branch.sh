#!/usr/bin/env bash
# Reviews a Libri worker branch before it merges to main: stock Claude Code's
# /code-review on the branch's changes against origin/main, its findings
# printed for Bridge to weigh. Main has no pull requests, so this stands in
# for the review a pull request would get; like Claude Code's GitHub review,
# it reports and leaves the merge to whoever runs it.
#
# The review runs in a throwaway detached checkout of the branch, so the
# caller's working tree and any release running in it are never touched.
# Read-only tools only: a review reads, it doesn't edit.
#
# On the seat's PATH as libri-review.
# Usage: libri-review BRANCH [LEVEL] [LIBRI_CHECKOUT]
#   LEVEL is /code-review's: low, medium (default), high or xhigh.
set -euo pipefail
branch=${1:?usage: libri-review BRANCH [LEVEL] [LIBRI_CHECKOUT]}
level=${2:-medium}
cd "${3:-$HOME/ark/libri}"

git fetch --quiet origin
ref=$(git rev-parse --verify --quiet "origin/$branch" || git rev-parse --verify "$branch")
commits=$(git rev-list --count "origin/main..$ref")
((commits > 0)) || { echo "$branch has nothing that main lacks"; exit 0; }
echo "Reviewing $branch: $commits commits, $(git diff --shortstat "origin/main...$ref")"
git log --format='  %h %s' "origin/main..$ref"
echo

tree=$(mktemp -d /tmp/libri-review.XXXXXX)
cleanup() { git worktree remove --force "$tree" 2>/dev/null || true; rm -rf "$tree"; }
trap cleanup EXIT
git worktree add --quiet --detach "$tree" "$ref"
base=$(git rev-parse origin/main)

cd "$tree"
# The prompt goes on stdin: --allowedTools takes the arguments after it.
echo "/code-review $level $base...HEAD" |
  timeout 3600 claude -p --model "${LIBRI_REVIEW_MODEL:-claude-opus-5-5}" \
    --allowedTools "Read,Grep,Glob,Agent,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git merge-base:*),Bash(git blame:*)"
