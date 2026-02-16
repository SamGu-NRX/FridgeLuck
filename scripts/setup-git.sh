#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

git -C "$REPO_ROOT" config --local core.hooksPath .githooks
git -C "$REPO_ROOT" config --local fetch.prune true
git -C "$REPO_ROOT" config --local pull.ff only

echo "Configured local git settings:"
echo "  core.hooksPath=.githooks"
echo "  fetch.prune=true"
echo "  pull.ff=only"
