#!/usr/bin/env bash
set -euo pipefail

preferred_name="${1:-iPhone}"

resolve_sim_id() {
  local name_pattern="$1"
  local line
  line="$(xcrun simctl list devices available | grep -E "$name_pattern" | head -n 1 || true)"
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

if resolve_sim_id "$preferred_name"; then
  exit 0
fi

if resolve_sim_id "iPhone|iPad"; then
  exit 0
fi

printf 'generic/platform=iOS Simulator\n'
