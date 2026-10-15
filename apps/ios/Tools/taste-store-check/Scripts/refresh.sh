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

# --- shared test text -----------------------------------------------------------
# The Linux suite must run the same test text as Tests/TasteStore/TasteEventStoreTests.swift
# so it cannot pass on code macOS CI rejects (that gap is how this check stayed green while
# macOS CI failed at 6ee4d4e: the mirrored fixture and the iOS fixture had drifted). The iOS
# file is sliced from its first shared MARK to EOF — everything above it is fixtures, and
# the fresh-install schema test lives in the iOS-only Tests/TasteStore/
# TasteSchemaFreshInstallTests.swift because it exercises DatabaseMigrations, the full app
# migration chain. The slice is pinned in TESTS.txt like the production sources; on drift,
# update the pin, re-run this script, and review the diff in TasteStoreLinuxTests.swift.

TESTS_PINNED_FILE="$SCRIPT_DIR/TESTS.txt"
IOS_TESTS_FILE="$IOS_ROOT/Tests/TasteStore/TasteEventStoreTests.swift"
MIRROR_TESTS_FILE="$CHECK_ROOT/Tests/TasteStoreCheckTests/TasteStoreLinuxTests.swift"
MIRROR_PREAMBLE="$CHECK_ROOT/Tests/TasteStoreCheckTests/TasteStoreLinuxPreamble.swift.part"

slice="$(mktemp)"
trap 'rm -f "$slice"' EXIT

while IFS=$'\t' read -r rel expected; do
  case "$rel" in '' | '#'*) continue ;; esac
  if [[ ! -f "$IOS_TESTS_FILE" ]]; then
    echo "missing iOS test file: $IOS_TESTS_FILE" >&2
    exit 1
  fi
  marker_line="$(grep -n '^  // MARK: - Idempotent append$' "$IOS_TESTS_FILE" | head -1 | cut -d: -f1)"
  if [[ -z "$marker_line" ]]; then
    echo "shared test MARK not found in $IOS_TESTS_FILE" >&2
    exit 1
  fi
  tail -n "+$marker_line" "$IOS_TESTS_FILE" > "$slice"
  if grep -q "DatabaseMigrations" "$slice"; then
    echo "shared test body references DatabaseMigrations (iOS-only): move it to an iOS-only file" >&2
    exit 1
  fi
  actual="$(sha256sum "$slice" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "hash drift for $rel — re-run refresh and review the diff" >&2
    exit 1
  fi
  cat "$MIRROR_PREAMBLE" "$slice" > "$MIRROR_TESTS_FILE"
  echo "regenerated $(basename "$MIRROR_TESTS_FILE") from $rel (shared test text in sync)"
done < "$TESTS_PINNED_FILE"
