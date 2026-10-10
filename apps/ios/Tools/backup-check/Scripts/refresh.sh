#!/usr/bin/env bash
# Copies the real production persistence sources into this package so the
# tests compile and run against the actual app code, not a fork.
#
# Run from anywhere: bash Scripts/refresh.sh (paths are package-relative).
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_ROOT="../.."
REAL="Sources/BackupCheck/Real"
rm -rf "$REAL"
mkdir -p "$REAL"

copy() {
  local src="$IOS_ROOT/$1"
  [ -f "$src" ] || { echo "missing real source: $src" >&2; exit 1; }
  cp "$src" "$REAL/"
}

# Persistence sources under test (paths relative to apps/ios).
copy Platform/Persistence/Database/Migrations.swift
copy Platform/Persistence/Backup/BackupArchive.swift
copy Platform/Persistence/Backup/BackupValidator.swift
copy Platform/Persistence/Backup/BackupRestoreEngine.swift

echo "refreshed $(ls "$REAL" | wc -l) real sources into $REAL"
