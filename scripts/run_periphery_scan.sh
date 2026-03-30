#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="${PROJECT_PATH:-$repo_root/FridgeLuck.xcodeproj}"
derived_data_path="${DERIVED_DATA_PATH:-$repo_root/.build/periphery-derived-data}"
reports_dir="${REPORTS_DIR:-$repo_root/reports/periphery}"
baseline_file="${BASELINE_FILE:-$repo_root/.periphery-baseline.json}"

"$repo_root/scripts/ensure_xcode_project.sh"

if [[ -n "${SCHEME_NAMES:-}" ]]; then
  read -r -a schemes <<< "$SCHEME_NAMES"
else
  schemes=(FridgeLuck FLFeatureLogic)
fi

if [[ ! -x "$(command -v periphery)" ]]; then
  echo "error: periphery is not installed. Install with: brew install periphery" >&2
  exit 1
fi

if [[ -n "${DESTINATION:-}" ]]; then
  destination="$DESTINATION"
else
  destination="$("$repo_root/scripts/resolve_ios_sim_destination.sh")"
fi

mkdir -p "$reports_dir"
rm -rf "$derived_data_path"
mkdir -p "$derived_data_path"

echo "Building index store for Periphery..."
xcodebuild build \
  -project "$project" \
  -scheme "${schemes[0]}" \
  -destination "$destination" \
  -derivedDataPath "$derived_data_path" \
  -quiet

index_store_path="$derived_data_path/Index.noindex/DataStore"
if [[ ! -d "$index_store_path" ]]; then
  echo "error: index store was not produced at: $index_store_path" >&2
  exit 1
fi

report_txt="$reports_dir/latest-app-only.txt"
report_json="$reports_dir/latest-app-only.json"

common_args=(
  scan
  --skip-build
  --index-store-path "$index_store_path"
  --project "$project"
  --schemes "${schemes[@]}"
  --exclude-tests
  --retain-swift-ui-previews
  --retain-codable-properties
  --disable-update-check
  --relative-results
  --quiet
)

if [[ -f "$baseline_file" ]]; then
  common_args+=(--baseline "$baseline_file")
fi

if [[ "${STRICT:-0}" == "1" ]]; then
  common_args+=(--strict)
fi

echo "Running Periphery scan (xcode format)..."
periphery "${common_args[@]}" --write-results "$report_txt" >/dev/null

echo "Running Periphery scan (json format)..."
periphery "${common_args[@]}" --format json --write-results "$report_json" >/dev/null

echo "Periphery reports written:"
echo "  - $report_txt"
echo "  - $report_json"
