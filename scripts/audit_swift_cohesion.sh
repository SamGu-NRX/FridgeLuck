#!/usr/bin/env bash
set -euo pipefail

# Non-blocking cohesion audit for Swift files.
# Purpose: flag files that may need review, not enforce hard limits.

ROOT_DIR="${1:-apps/ios}"
GUIDELINE_LOC="${GUIDELINE_LOC:-450}"
TOP_N="${TOP_N:-30}"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required for this script."
  exit 1
fi

if [ ! -d "$ROOT_DIR" ]; then
  echo "Directory not found: $ROOT_DIR"
  exit 1
fi

echo "Swift cohesion audit"
echo "Root: $ROOT_DIR"
echo "Guideline LOC (non-blocking): $GUIDELINE_LOC"
echo

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

rg --files "$ROOT_DIR" -g '*.swift' \
  -g '!**/Vendor/**' \
  -g '!**/.build/**' \
  | while IFS= read -r file; do
      lines="$(wc -l < "$file" | tr -d ' ')"
      printf "%6d %s\n" "$lines" "$file"
    done \
  | sort -nr > "$TMP_FILE"

echo "Top $TOP_N largest Swift files:"
head -n "$TOP_N" "$TMP_FILE"
echo

echo "Files above guideline ($GUIDELINE_LOC LOC):"
awk -v limit="$GUIDELINE_LOC" '$1 > limit { print }' "$TMP_FILE" || true
echo

echo "Audit complete. Review high-LOC files for mixed concerns and split only when cohesion is poor."
