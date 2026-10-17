#!/usr/bin/env bash
# Copies the real production substitution sources into this package so the
# tests compile and run against the actual app code, not a fork.
#
# Run from anywhere: bash Scripts/refresh.sh (paths are package-relative).
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_ROOT="../.."
REAL="Sources/SubstitutionEvidence/Real"
rm -rf "$REAL"
mkdir -p "$REAL"

copy() {
  local src="$IOS_ROOT/$1"
  [ -f "$src" ] || { echo "missing real source: $src" >&2; exit 1; }
  cp "$src" "$REAL/"
}

# Production sources under replay (paths relative to apps/ios).
copy Platform/Persistence/Services/SubstitutionService.swift
copy Domain/Models/Ingredient.swift

echo "refreshed $(ls "$REAL" | wc -l) real sources into $REAL"
