#!/usr/bin/env bash
# Builds the check package, installs the shipped bundle fixtures where the
# Linux test runner's Bundle.main resolves them (next to the test-runner
# executable — the equivalent of the iOS test host's app bundle), then runs
# the tests. On iOS the app bundle carries these resources; on Linux the
# check package must provide them the same way.
#
#   bash Scripts/refresh.sh
#   bash Scripts/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests

RUNNER=$(find .build -type f -name "*-test-runner" | head -1)
if [ -z "$RUNNER" ]; then
  echo "test runner executable not found under .build" >&2
  exit 1
fi
RUNNER_DIR=$(dirname "$RUNNER")

FIX="Tests/FridgeLuckCheckTests/Fixtures"
cp "$FIX/data.json" "$RUNNER_DIR/"
rm -rf "$RUNNER_DIR/LegacyBundles"
cp -R "$FIX/LegacyBundles" "$RUNNER_DIR/"
cp "$FIX/usda_ingredient_catalog.sqlite" "$RUNNER_DIR/"

swift test --skip-build
