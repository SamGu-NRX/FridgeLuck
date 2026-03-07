#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET_DIR="FridgeLuck.swiftpm"

echo "Checking code for runtime network calls..."
NETWORK_HITS=$(
  rg -n "URLSession|http://|https://" "$TARGET_DIR" \
    -g'*.swift' \
    --glob '!**/Vendor/**' || true
)
if [ -n "$NETWORK_HITS" ]; then
  echo "$NETWORK_HITS"
fi

echo "Checking vendored dependency path..."
if [ ! -f "$TARGET_DIR/Vendor/GRDB.swift/Package.swift" ]; then
  echo "ERROR: Vendored GRDB package is missing."
  exit 1
fi

echo "Checking for permission descriptions..."
if ! rg -q "NSCameraUsageDescription" "$TARGET_DIR/Support/AdditionalInfo.plist"; then
  echo "ERROR: NSCameraUsageDescription missing."
  exit 1
fi
if ! rg -q "NSPhotoLibraryUsageDescription" "$TARGET_DIR/Support/AdditionalInfo.plist"; then
  echo "ERROR: NSPhotoLibraryUsageDescription missing."
  exit 1
fi
if ! rg -q "NSMicrophoneUsageDescription" "$TARGET_DIR/Support/AdditionalInfo.plist"; then
  echo "ERROR: NSMicrophoneUsageDescription missing."
  exit 1
fi

echo "Offline audit complete."
echo "Final manual check: run app once with Wi-Fi disabled."
