#!/usr/bin/env bash
# Boots the community e2e server (production wiring on the in-memory store, test seams) and
# runs the Swift client walk against it. Server and walk both die with this shell.
#
#   scripts/community-e2e/run.sh            # refresh mirror, build, run
#
# Env:
#   PORT            fixed port for the community server (default: ephemeral)
#   SKIP_REFRESH=1  skip the source-mirror refresh (not recommended)
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"   # repo root
server="$root/backend/community/scripts/e2e-server.ts"
walk="$root/apps/ios/Tools/community-e2e"

# --- Boot the server, capture its one JSON bootstrap line {port, apple, operatorSub}.
boot="$(mktemp)"
bun "$server" > "$boot" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -f "$boot"' EXIT

for _ in $(seq 1 100); do
  if [ -s "$boot" ] && grep -q '"port"' "$boot"; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "e2e server exited during boot:" >&2
    cat "$boot" >&2
    exit 1
  fi
  sleep 0.1
done
grep -q '"port"' "$boot" || { echo "e2e server never reported its port" >&2; exit 1; }

port="$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$boot")"
apple="$(sed -n 's/.*"apple":\([0-9]*\).*/\1/p' "$boot")"
test -n "$port" && test -n "$apple" || { echo "could not parse the e2e boot line:"; cat "$boot"; exit 1; }

# --- Build (and refresh) the walk package.
if [ "${SKIP_REFRESH:-0}" != "1" ]; then
  "$walk/refresh.sh"
fi
cd "$walk"
# --allow-shlib-undefined: the Swift toolchain's libswiftObservation.so references a hidden
# libswiftCore symbol that Debian's stricter ld refuses; Ubuntu's tolerates it.
swift build -Xlinker --allow-shlib-undefined

# --- Run the walk through the real client stack.
export COMMUNITY_E2E_BASE="http://127.0.0.1:$port/v1"
export COMMUNITY_E2E_APPLE="http://127.0.0.1:$apple"
.build/debug/CommunityE2EWalk
