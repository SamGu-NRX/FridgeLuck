#!/usr/bin/env bash
# Runs the LeChef end-to-end walk: the phone (pinned production Swift sources,
# built here) and the gateway (the boot's parameterized server with the
# scripted fake model) over a real WebSocket on localhost.
#
# Requires: a Linux Swift toolchain on PATH (or SWIFT_BIN pointing at one) and
# bun for the backend boot.
#
#   ./run.sh
#
# The walk and the boot each assert their own side; either failing fails the
# run. Pins are verified first (./verify.sh) so the built walk is the real
# phone.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"

swift_bin="${SWIFT_BIN:-$(command -v swift || true)}"
if [ -z "$swift_bin" ]; then
  for candidate in "$HOME"/swift*/usr/bin/swift /usr/local/bin/swift; do
    if [ -x "$candidate" ]; then swift_bin="$candidate"; break; fi
  done
fi
if [ -z "$swift_bin" ]; then
  echo "run.sh: no swift toolchain found (set SWIFT_BIN)" >&2
  exit 2
fi
swift_dir="$(dirname "$swift_bin")"

echo "run.sh: verifying pinned phone sources"
"$here/verify.sh"

echo "run.sh: building the walk ($swift_bin)"
cd "$here"
PATH="$swift_dir:$PATH" "$swift_bin" build

echo "run.sh: typechecking the backend"
cd "$repo/backend/gemini-agent"
bun run check

echo "run.sh: starting the gateway with the scripted model and running the walk"
cd "$repo"
LECHEF_E2E_WALK_BIN="$here/.build/debug/lechef-e2e" bun run backend/gemini-agent/src/lechef/e2e/boot.ts
