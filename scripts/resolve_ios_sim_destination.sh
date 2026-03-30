#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="${PROJECT_PATH:-$repo_root/FridgeLuck.xcodeproj}"
scheme="${SCHEME_NAME:-FridgeLuck}"
preferred_name="${1:-iPhone 17 Pro}"

extract_sim_id() {
  sed -E 's/.*id:([0-9A-F-]{36}).*/\1/' <<<"$1"
}

resolve_sim_id_from_xcodebuild() {
  local name_pattern="$1"
  local line
  line="$(
    xcodebuild -showdestinations -project "$project" -scheme "$scheme" 2>/dev/null \
      | grep "platform:iOS Simulator" \
      | grep -E "name:${name_pattern}" \
      | head -n 1 || true
  )"
  if [[ -z "$line" ]]; then
    return 1
  fi

  local sim_id
  sim_id="$(extract_sim_id "$line")"
  if [[ "$sim_id" =~ ^[0-9A-F-]{36}$ ]]; then
    printf 'id=%s\n' "$sim_id"
    return 0
  fi

  return 1
}

resolve_sim_id_from_simctl() {
  local name_pattern="$1"
  local line
  line="$(
    xcrun simctl list devices available \
      | grep -E "^[[:space:]]+${name_pattern} \\([0-9A-F-]{36}\\)" \
      | head -n 1 || true
  )"
  if [[ -z "$line" ]]; then
    return 1
  fi

  local sim_id
  sim_id="$(sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' <<<"$line")"
  if [[ "$sim_id" =~ ^[0-9A-F-]{36}$ ]]; then
    printf 'id=%s\n' "$sim_id"
    return 0
  fi

  return 1
}

if [[ -d "$project" ]] && resolve_sim_id_from_xcodebuild "$preferred_name"; then
  exit 0
fi

if [[ -d "$project" ]] && resolve_sim_id_from_xcodebuild "iPhone|iPad"; then
  exit 0
fi

if resolve_sim_id_from_simctl "$preferred_name"; then
  exit 0
fi

if resolve_sim_id_from_simctl "iPhone|iPad"; then
  exit 0
fi

printf 'generic/platform=iOS Simulator\n'
