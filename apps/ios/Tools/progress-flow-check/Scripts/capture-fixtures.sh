#!/usr/bin/env bash
# Fixture capture for the Progress flow — macOS/Xcode ONLY.
#
# STATUS: UNEXECUTED. This host is Debian Linux with no Xcode; the script
# has never been run here. It was written to be runnable on a macOS host
# with Xcode 26.x. It must never be substituted with webmocks, browser
# screenshots, or Playwright/axe output — those are web tools and this is
# a native SwiftUI surface.
#
# What it does, on a macOS host:
#   1. Builds the FridgeLuck app for the iOS simulator.
#   2. Boots an iPhone-class simulator (390x844 pt) and an iPad-class
#      simulator (1440x900 pt class) and captures the Progress tab at
#      each size from synthetic fixture data.
#   3. Exports PNGs into Results/captures/.
#   4. Runs the native accessibility audit path: an XCUITest that calls
#      performAccessibilityAudit() on the Progress tab (iOS 17+ API).
#
# PREREQUISITE (one-time, DEBUG-only): the app must seed synthetic journal
# data when launched with FL_SEED_PROGRESS_FIXTURES=1. The offline test
# package (Tests/ProgressReadModelTests.swift) shows exactly which rows to
# write (categories + cooking_journal via PersonalizationService.recordCooking
# after the real migrations). If that launch hook is not present in
# MyApp.swift yet, add it behind #if DEBUG before running this script —
# do not fake the data with screenshots of an empty state.
#
# Usage (on macOS):  Scripts/capture-fixtures.sh /path/to/FridgeLuck.xcodeproj
set -euo pipefail

PROJECT_PATH="${1:?usage: capture-fixtures.sh /path/to/FridgeLuck.xcodeproj}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/Results/captures"
mkdir -p "$OUT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "REFUSED: this script requires macOS + Xcode (host is $(uname -s))." >&2
  echo "The PNG captures and native a11y audit remain UNEXECUTED on this host." >&2
  exit 1
fi

command -v xcodebuild >/dev/null || { echo "xcodebuild not found" >&2; exit 1; }

run_capture() {
  local scheme_device="$1" out_name="$2"
  local sim_name="fl-progress-capture-$(echo "$scheme_device" | tr ' ' '-')"

  xcrun simctl delete "$sim_name" 2>/dev/null || true
  local sim_id
  sim_id="$(xcrun simctl create "$sim_name" "$scheme_device")"
  xcrun simctl boot "$sim_id"

  xcodebuild -project "$PROJECT_PATH" -scheme FridgeLuck \
    -destination "id=$sim_id" -configuration Debug build

  local app_path
  app_path="$(xcodebuild -project "$PROJECT_PATH" -scheme FridgeLuck \
    -destination "id=$sim_id" -configuration Debug -showBuildSettings build 2>/dev/null \
    | awk -F' = ' '/ TARGET_BUILD_DIR /{print $2; exit}')/FridgeLuck.app"

  xcrun simctl install "$sim_id" "$app_path"
  xcrun simctl launch --terminate-running-process "$sim_id" \
    -FL_SEED_PROGRESS_FIXTURES=1 samgu.FridgeLuck

  # Let the fixture seed and the Progress tab settle, then capture.
  sleep 6
  xcrun simctl io "$sim_id" screenshot "$OUT_DIR/$out_name.png"
  echo "captured $OUT_DIR/$out_name.png"

  # Native accessibility audit (XCUITest performAccessibilityAudit) —
  # requires a UI test target in the Xcode project; SKIP with a reason if
  # absent rather than substituting a web tool.
  if xcodebuild -project "$PROJECT_PATH" -list 2>/dev/null | grep -q "FridgeLuckUITests"; then
    xcodebuild -project "$PROJECT_PATH" -scheme FridgeLuck \
      -destination "id=$sim_id" test -only-testing:FridgeLuckUITests/ProgressAccessibilityAuditTests \
      2>&1 | tee "$OUT_DIR/$out_name-a11y-audit.log"
  else
    echo "SKIP: no FridgeLuckUITests target — a11y audit unexecuted for $out_name" \
      | tee "$OUT_DIR/$out_name-a11y-audit.log"
  fi

  xcrun simctl shutdown "$sim_id" || true
  xcrun simctl delete "$sim_id" || true
}

run_capture "iPhone 16 Pro" "progress-390x844"
run_capture "iPad Pro 11-inch (M4)" "progress-1440x900"

echo "Fixture capture complete. Results are evidence for the PR; do not edit PNGs by hand."
