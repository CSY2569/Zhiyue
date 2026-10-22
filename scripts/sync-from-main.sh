#!/usr/bin/env bash
# Sync shared changes from `main` into the current platform branch.
#
# Background: `main` owns the desktop line and has no Android files, so a
# plain `git merge main` would DELETE every Android-only file that the branch
# did not touch. This script merges, then restores those paths from the
# pre-merge tip listed in `.platform/android-owned.txt`.
#
# Usage: bash scripts/sync-from-main.sh [source-branch]
set -euo pipefail

SOURCE="${1:-main}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
MANIFEST="$(git rev-parse --show-toplevel)/.platform/android-owned.txt"

if [ "$BRANCH" = "$SOURCE" ]; then
  echo "error: run this from the platform branch, not $SOURCE" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "error: missing $MANIFEST" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty; commit or stash first" >&2
  exit 1
fi

TIP="$(git rev-parse HEAD)"
echo "==> merging $SOURCE into $BRANCH (tip $TIP)"
git merge --no-commit --no-ff "$SOURCE" || true

RESTORED=0
while IFS= read -r path; do
  [ -z "$path" ] && continue
  case "$path" in \#*) continue ;; esac
  if git checkout "$TIP" -- "$path" 2>/dev/null; then
    RESTORED=$((RESTORED + 1))
  fi
done < "$MANIFEST"

git add -A
if git diff --cached --quiet; then
  echo "==> nothing to commit ($SOURCE already merged)"
else
  git commit -m "merge: sync shared changes from $SOURCE"
fi
echo "==> restored $RESTORED platform-owned paths"
echo "==> verify with: flutter analyze && flutter test"
