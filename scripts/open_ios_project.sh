#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repo_root/FridgeLuck.xcodeproj"

"$repo_root/scripts/ensure_xcode_project.sh"

echo "Opening $project_file..."
open "$project_file"
