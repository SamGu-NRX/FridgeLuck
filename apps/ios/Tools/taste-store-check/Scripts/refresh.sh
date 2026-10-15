#!/usr/bin/env bash
# Mirrors the taste persistence production sources into Sources/TasteStoreCheck and
# verifies their content against pinned hashes. If a hash mismatch is reported, the
# production source changed after the mirror was refreshed: re-run this script and
# review the diff, then update SOURCES.txt. Never hand-edit the mirrored files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IOS_ROOT="$(cd "$CHECK_ROOT/../.." && pwd)"
MIRROR_DIR="$CHECK_ROOT/Sources/TasteStoreCheck"

# source_path<TAB>sha256, pinned so drift between production and mirror is caught here
# instead of becoming a silent behavior difference.
PINNED_FILE="$SCRIPT_DIR/SOURCES.txt"

while IFS=$'\t' read -r rel expected; do
  case "$rel" in '' | '#'*) continue ;; esac
  src="$IOS_ROOT/$rel"
  dst="$MIRROR_DIR/$(basename "$rel")"
  if [[ ! -f "$src" ]]; then
    echo "missing production source: $rel" >&2
    exit 1
  fi
  actual="$(sha256sum "$src" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "hash drift for $rel — re-run refresh and review the diff" >&2
    exit 1
  fi
  cp "$src" "$dst"
  echo "mirrored $rel"
done < "$PINNED_FILE"

echo "taste-store-check mirror is in sync"
