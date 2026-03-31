#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="${PROJECT_PATH:-$repo_root/FridgeLuck.xcodeproj}"
scheme="${SCHEME_NAME:-FridgeLuck}"

"$repo_root/scripts/ensure_xcode_project.sh"

if [[ -n "${DESTINATION:-}" ]]; then
  destination="$DESTINATION"
else
  destination="$("$repo_root/scripts/resolve_ios_sim_destination.sh")"
fi

xcodebuild_args=(
  test
  -project "$project"
  -scheme "$scheme"
  -destination "$destination"
)

if [[ -n "${SIMULATOR_DEPLOYMENT_TARGET:-}" ]]; then
  xcodebuild_args+=(IPHONEOS_DEPLOYMENT_TARGET="$SIMULATOR_DEPLOYMENT_TARGET")
fi

xcodebuild "${xcodebuild_args[@]}"
