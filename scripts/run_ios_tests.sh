#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="${WORKSPACE_PATH:-$repo_root/FridgeLuck.swiftpm/.swiftpm/xcode/package.xcworkspace}"
scheme="${SCHEME_NAME:-FridgeLuck}"

if [[ -n "${DESTINATION:-}" ]]; then
  destination="$DESTINATION"
else
  destination="$("$repo_root/scripts/resolve_ios_sim_destination.sh" iPhone)"
fi

# SwiftPM .iOSApplication generation currently emits a reproducible duplicate asset
# warning for the app asset catalog in Compile Sources. Filter that single known line
# to keep CI logs actionable while preserving the actual xcodebuild exit status.
xcodebuild test \
  -workspace "$workspace" \
  -scheme "$scheme" \
  -destination "$destination" 2>&1 \
  | sed '/Skipping duplicate build file in Compile Sources build phase: .*AppAssets\.xcassets/d'
