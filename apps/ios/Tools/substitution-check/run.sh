#!/bin/bash
set -euo pipefail
# Portable check: compiles the production SubstitutionTable logic plus the
# check main against the generated app resource and runs the assertions.
#
# Usage: bash run.sh [PATH_TO_SUBSTITUTIONS_V1_JSON]
# Default resource: apps/ios/Resources/Substitutions/substitutions-v1.json
TOOL_DIR="$(dirname "$(realpath "$0")")"
IOS_DIR="$(realpath "$TOOL_DIR/../..")"
RESOURCE="${1:-$IOS_DIR/Resources/Substitutions/substitutions-v1.json}"

BUILD_DIR="$(mktemp -d /tmp/fl-tc/substitution-check/build.XXXXXX)"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

cp "$IOS_DIR/FeatureLogic/Substitution/SubstitutionTable.swift" "$BUILD_DIR/"
cp "$TOOL_DIR/main.swift" "$BUILD_DIR/"

SWIFT="${SWIFT_BIN:-swiftc}"
"$SWIFT" -O \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$BUILD_DIR/SubstitutionTable.swift" "$BUILD_DIR/main.swift" \
  -o "$BUILD_DIR/substitution-check"

"$BUILD_DIR/substitution-check" "$RESOURCE"
