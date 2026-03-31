#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="${PROJECT_PATH:-$repo_root/FridgeLuck.xcodeproj}"
scheme="${SCHEME_NAME:-FridgeLuck}"
configuration="${CONFIGURATION:-Debug}"
sdk="${SDK_NAME:-iphoneos}"

"$repo_root/scripts/ensure_xcode_project.sh"

build_settings="$(
  xcodebuild -project "$project" -scheme "$scheme" -configuration "$configuration" -sdk "$sdk" -showBuildSettings
)"

target_build_dir="$(
  printf '%s\n' "$build_settings" | awk -F' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }'
)"
full_product_name="$(
  printf '%s\n' "$build_settings" | awk -F' = ' '/ FULL_PRODUCT_NAME = / { print $2; exit }'
)"

if [[ -z "$target_build_dir" || -z "$full_product_name" ]]; then
  echo "error: unable to resolve built app path from xcodebuild settings" >&2
  exit 1
fi

app_path="$target_build_dir/$full_product_name"

if [[ ! -d "$app_path" ]]; then
  echo "error: built app not found at $app_path" >&2
  echo "build the $scheme scheme for a device first, then rerun this script." >&2
  exit 1
fi

echo "Inspecting entitlements for $app_path"
entitlements="$(codesign --display --entitlements :- "$app_path" 2>/dev/null || true)"

if [[ -z "$entitlements" ]]; then
  echo "error: unable to read entitlements from signed app" >&2
  exit 1
fi

printf '%s\n' "$entitlements"

if printf '%s\n' "$entitlements" | grep -q "com.apple.developer.healthkit"; then
  echo "HealthKit entitlement present."
else
  echo "error: HealthKit entitlement missing from signed app." >&2
  exit 1
fi
