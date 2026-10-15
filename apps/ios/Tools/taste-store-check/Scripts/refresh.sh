#!/usr/bin/env bash
# Mirrors the taste production sources into Sources/TasteStoreCheck (relative paths
# preserved) and the TasteProfile test files into Tests/TasteStoreCheckTests, verifying
# content against pinned hashes. If a hash mismatch is reported, the production source
# changed after the mirror was refreshed: re-run this script and review the diff, then
# update SOURCES.txt. Never hand-edit the mirrored files.
#
# The statement builder is mirrored under Sources/FLFeatureLogic — the repository and
# view model `import FLFeatureLogic` by module name, so the check package carries a
# target with that exact name holding the FeatureLogic sources the profile feature uses.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IOS_ROOT="$(cd "$CHECK_ROOT/../.." && pwd)"
MIRROR_DIR="$CHECK_ROOT/Sources/TasteStoreCheck"
BUILDER_MIRROR_DIR="$CHECK_ROOT/Sources/FLFeatureLogic"
TESTS_MIRROR_DIR="$CHECK_ROOT/Tests/TasteStoreCheckTests"

# source_path<TAB>sha256, pinned so drift between production and mirror is caught here
# instead of becoming a silent behavior difference.
PINNED_FILE="$SCRIPT_DIR/SOURCES.txt"

while IFS=$'\t' read -r rel expected; do
  case "$rel" in '' | '#'*) continue ;; esac
  src="$IOS_ROOT/$rel"
  case "$rel" in
    FeatureLogic/*)
      dst="$BUILDER_MIRROR_DIR/$rel"
      ;;
    Tests/*)
      dst="$TESTS_MIRROR_DIR/${rel#Tests/}"
      ;;
    *)
      dst="$MIRROR_DIR/$rel"
      ;;
  esac
  if [[ ! -f "$src" ]]; then
    echo "missing production source: $rel" >&2
    exit 1
  fi
  actual="$(sha256sum "$src" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "hash drift for $rel — re-run refresh and review the diff" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "mirrored $rel"
done < "$PINNED_FILE"

echo "taste-store-check mirror is in sync"
