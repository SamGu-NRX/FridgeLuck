#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_spec="${PROJECT_SPEC_PATH:-$repo_root/project.yml}"
project_path="${PROJECT_PATH:-$repo_root/FridgeLuck.xcodeproj}"

required_outputs=(
  "$project_path/project.pbxproj"
  "$repo_root/Xcode/FridgeLuck-Info.plist"
  "$repo_root/Xcode/FridgeLuck.entitlements"
)

validate_required_outputs() {
  local report_missing="${1:-1}"
  local output
  local missing_output=0

  for output in "${required_outputs[@]}"; do
    if [[ ! -e "$output" ]]; then
      missing_output=1
      if [[ "$report_missing" == "1" ]]; then
        echo "error: generated Xcode project at $project_path is incomplete; missing required output: $output" >&2
      fi
    fi
  done

  return "$missing_output"
}

if validate_required_outputs 0; then
  exit 0
fi

if [[ ! -x "$(command -v xcodegen)" ]]; then
  echo "error: xcodegen is required to generate the Xcode project from $project_spec" >&2
  echo "install it with: brew install xcodegen" >&2
  exit 1
fi

echo "Generating Xcode project from $project_spec..."
(
  cd "$repo_root"
  xcodegen generate --spec "$project_spec"
)

validate_required_outputs 1
