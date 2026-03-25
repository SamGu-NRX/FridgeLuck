#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repo_root/FridgeLuck.xcodeproj"

if [[ ! -x "$(command -v xcodegen)" ]]; then
  echo "error: xcodegen is not installed. Install with: brew install xcodegen" >&2
  exit 1
fi

echo "Generating Xcode project from project.yml..."
cd "$repo_root"
xcodegen generate

echo "Opening $project_file..."
open "$project_file"
