#!/usr/bin/env bash
# Full replay runner (recorded command, run from the repository root).
#
#   bash apps/ios/Tools/scan-correction-eval/SwiftReplay/Scripts/run_replay.sh
#
# Syncs production sources into the package (fail on drift with --check),
# then runs swift test over all 300 histories x 4 arms. The
# -DSQLITE_DISABLE_SNAPSHOT define is required to build GRDB 7.10.0 on this
# Linux toolchain (no snapshot APIs in the system SQLite build).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd)"
TOOL_DIR="$REPO_ROOT/apps/ios/Tools/scan-correction-eval"

python3 "$TOOL_DIR/SwiftReplay/Scripts/sync_sources.py" --check

# Resolve Swift if not on PATH (project toolchain lives at
# /home/user/work/swift-toolchain).
if ! command -v swift >/dev/null 2>&1; then
  export PATH="/home/user/work/swift-toolchain/usr/bin:$PATH"
fi

swift test \
  --package-path "$TOOL_DIR/SwiftReplay" \
  -Xswiftc -DSQLITE_DISABLE_SNAPSHOT \
  2>&1 | tee "$TOOL_DIR/data/replay-swift-test.log"

# Fail the script if any test failed (tee swallows the exit code above).
test "${PIPESTATUS[0]}" -eq 0
