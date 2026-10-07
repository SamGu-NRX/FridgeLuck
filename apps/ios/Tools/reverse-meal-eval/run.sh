#!/bin/bash
set -euo pipefail
# Invoke with bash run.sh STATES_JSONL REPLAY_JSON. Build products stay in our scratch directory.
if [ "$#" -ne 2 ]; then echo 'usage: bash run.sh STATES_JSONL REPLAY_JSON' >&2; exit 1; fi
TOOL_DIR="$(dirname "$(realpath "$0")")"
IOS_DIR="$(realpath "$TOOL_DIR/../..")"
BUILD_DIR=/tmp/fl-tc/reverse-meal
mkdir -p "$BUILD_DIR/module-cache"
LEASE_TOOL="$HOME/.long-run/bin/lr-lease"
lease_id=''
release_lease() {
  if [ -n "$lease_id" ]; then
    "$LEASE_TOOL" release "$lease_id"
    lease_id=''
  fi
}
trap release_lease EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# The shell owning $$ remains alive through lockf and swiftc. Never compile on exit 75.
deadline=$(( $(date +%s) + 1200 ))
while true; do
  "$HOME/.long-run/bin/lr-reap" --run fridgeluck >&2
  set +e
  admission=$("$LEASE_TOOL" acquire --run fridgeluck --kind heavy --est-mem 1 --est-disk 0.3 --ttl 30 --owner-pid $$)
  status=$?
  set -e
  if [ "$status" -ne 0 ] && [ "$status" -ne 75 ]; then
    echo "blocked: lease: $admission" >&2
    exit "$status"
  fi
  if [ "$status" -eq 0 ]; then lease_id="$admission"; fi
  disk=$(df -k /)
  printf '%s\n' "$disk" >&2
  free_kib=$(printf '%s\n' "$disk" | awk 'END {print $4}')
  if [ "$status" -eq 0 ] && [ "$free_kib" -ge 8388608 ]; then break; fi
  release_lease
  if [ "$free_kib" -lt 8388608 ] || [[ "$admission" == *disk* ]]; then
    blocker="blocked: disk: $admission; available=${free_kib} KiB; floor=8388608 KiB"
  else
    blocker="blocked: lease: $admission"
  fi
  echo "$blocker" >&2
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then exit 75; fi
  remaining=$(( deadline - now ))
  delay=120
  if [ "$remaining" -lt "$delay" ]; then delay="$remaining"; fi
  sleep "$delay"
done
python3 -B - "$IOS_DIR" "$BUILD_DIR" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, build = map(Path, sys.argv[1:])
paths = [root/'Platform/Persistence/Services/ConfidenceLearningService.swift', root/'Platform/Persistence/Database/Migrations.swift', root/'Tools/reverse-meal-eval/main.swift']
record = {'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, 'build_script_sha256': hashlib.sha256((root/'Tools/reverse-meal-eval/run.sh').read_bytes()).hexdigest()}
(build/'compile-inputs.json').write_text(json.dumps(record, sort_keys=True))
PY
/usr/bin/lockf -k "$HOME/.long-run/locks/heavy.lock" swiftc \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -I /tmp/fl-tc/grdb -I "$IOS_DIR/Vendor/GRDB.swift/Sources/GRDBSQLite" \
  -L /tmp/fl-tc/grdb -lGRDB -Xlinker -rpath -Xlinker /tmp/fl-tc/grdb \
  "$IOS_DIR/Platform/Persistence/Services/ConfidenceLearningService.swift" \
  "$IOS_DIR/Platform/Persistence/Database/Migrations.swift" \
  "$TOOL_DIR/main.swift" -o "$BUILD_DIR/reverse-meal-runner"
release_lease
python3 -B - "$BUILD_DIR" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
build = Path(sys.argv[1])
inputs = json.loads((build/'compile-inputs.json').read_text())
for path, expected in inputs['sources'].items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
        raise SystemExit('Compile input changed during build: ' + path)
paths = [build/'reverse-meal-runner', Path('/tmp/fl-tc/grdb/libGRDB.dylib'), Path('/tmp/fl-tc/grdb/GRDB.swiftmodule')]
record = {**inputs, 'binary_and_grdb': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, 'swift_version': subprocess.check_output(['swiftc', '--version'], text=True), 'compile_admission': 'lr-lease heavy, lockf heavy.lock, 8 GiB floor on df -k /'}
(build/'build-record.json').write_text(json.dumps(record, sort_keys=True, separators=(',', ':')) + '\n')
PY
"$BUILD_DIR/reverse-meal-runner" "$1" "$2"
