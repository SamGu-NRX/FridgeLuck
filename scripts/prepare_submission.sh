#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ZIP_NAME="FridgeLuck.zip"
TARGET_DIR="FridgeLuck.swiftpm"

find "$TARGET_DIR" -name '.DS_Store' -delete
rm -f "$ZIP_NAME"

zip -rq "$ZIP_NAME" "$TARGET_DIR"

ZIP_BYTES=$(stat -f%z "$ZIP_NAME")
ZIP_MB=$(awk "BEGIN {printf \"%.2f\", $ZIP_BYTES / 1024 / 1024}")

printf "Created %s (%s MB)\n" "$ZIP_NAME" "$ZIP_MB"

MAX_BYTES=$((25 * 1024 * 1024))
if [ "$ZIP_BYTES" -ge "$MAX_BYTES" ]; then
  echo "ERROR: Zip exceeds 25 MB submission limit."
  exit 1
fi

echo "Submission package is within size limit."
