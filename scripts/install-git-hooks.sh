#!/usr/bin/env bash
#
# Install the tracked git hooks from .githooks/ by pointing git's
# core.hooksPath at that directory. Runs per clone (not global).
#
# Why this script instead of a symlink: .git/hooks/ is not tracked by git,
# and symlinks can silently break on some filesystems (Windows / CI workers).
# Setting core.hooksPath is a one-line, portable solution that makes every
# file in .githooks/ an active hook for this repo only.
#
# Hooks currently installed:
#   - pre-commit: reject edits to migration files already on origin/main
#                 (see .githooks/pre-commit for the full story)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

if [ ! -d .git ]; then
  echo "✖  $REPO_ROOT is not a git repository" >&2
  exit 1
fi

if [ ! -d .githooks ]; then
  echo "✖  .githooks/ directory is missing at $REPO_ROOT/.githooks" >&2
  exit 1
fi

# Make sure all tracked hooks are executable (git refuses to run non-executable hooks)
chmod +x .githooks/*

git config core.hooksPath .githooks

echo "✔  Installed git hooks from .githooks/"
echo "   (core.hooksPath is now set to .githooks for this clone)"
echo
echo "Active hooks:"
for hook in .githooks/*; do
  [ -f "$hook" ] || continue
  printf "   • %s\n" "$(basename "$hook")"
done
