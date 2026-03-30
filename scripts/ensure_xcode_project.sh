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

project_is_ready=1
for output in "${required_outputs[@]}"; do
  if [[ ! -e "$output" ]]; then
    project_is_ready=0
    break
  fi
done

if [[ "$project_is_ready" == "1" ]]; then
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
