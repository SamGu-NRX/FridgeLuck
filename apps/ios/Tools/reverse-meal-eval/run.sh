#!/bin/bash
set -euo pipefail
# Result and execution record go to the caller's fresh directory; each build has its own directory.
if [ "$#" -ne 4 ] || [ "$3" != '--result' ]; then echo 'usage: bash run.sh STATES_JSONL REPLAY_JSON --result RESULT_JSON' >&2; exit 1; fi
TOOL_DIR="$(dirname "$(realpath "$0")")"
IOS_DIR="$(realpath "$TOOL_DIR/../..")"
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
mkdir -p /tmp/fl-tc/reverse-meal
build_dir=$(mktemp -d /tmp/fl-tc/reverse-meal/build.XXXXXX)
echo "build_dir=$build_dir" >&2
mkdir -p "$build_dir/module-cache" "$build_dir/inputs" "$build_dir/grdb"
python3 -B - "$IOS_DIR" "$build_dir" <<'PY'
import hashlib, json, shutil, sys
from pathlib import Path
root, build = map(Path, sys.argv[1:])
paths = [root/'Platform/Persistence/Services/ConfidenceLearningService.swift', root/'Platform/Persistence/Database/Migrations.swift', root/'Tools/reverse-meal-eval/main.swift']
sources = {}
for path in paths:
    data = path.read_bytes()
    (build/'inputs'/path.name).write_bytes(data)
    sources[str(path)] = hashlib.sha256(data).hexdigest()
for name in ['libGRDB.dylib', 'GRDB.swiftmodule', 'GRDB.swiftdoc']:
    shutil.copyfile(Path('/tmp/fl-tc/grdb')/name, build/'grdb'/name)
shutil.copytree(root/'Vendor/GRDB.swift/Sources/GRDBSQLite', build/'inputs/GRDBSQLite')
record = {'sources': sources, 'build_script_sha256': hashlib.sha256((root/'Tools/reverse-meal-eval/run.sh').read_bytes()).hexdigest()}
(build/'compile-inputs.json').write_text(json.dumps(record, sort_keys=True))
snapshots = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for directory in [build/'inputs', build/'grdb'] for p in directory.rglob('*') if p.is_file()}
(build/'snapshot-hashes.json').write_text(json.dumps(snapshots, sort_keys=True))
PY
/usr/bin/lockf -k "$HOME/.long-run/locks/heavy.lock" swiftc \
  -module-cache-path "$build_dir/module-cache" \
  -I "$build_dir/grdb" -I "$build_dir/inputs/GRDBSQLite" \
  -L "$build_dir/grdb" -lGRDB -Xlinker -rpath -Xlinker "$build_dir/grdb" \
  "$build_dir/inputs/ConfidenceLearningService.swift" \
  "$build_dir/inputs/Migrations.swift" \
  "$build_dir/inputs/main.swift" -o "$build_dir/reverse-meal-runner"
release_lease
python3 -B - "$build_dir" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
build = Path(sys.argv[1])
inputs = json.loads((build/'compile-inputs.json').read_text())
for path, expected in {**inputs['sources'], **json.loads((build/'snapshot-hashes.json').read_text())}.items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
        raise SystemExit('Compile input changed during build: ' + path)
paths = [build/'reverse-meal-runner', build/'grdb/libGRDB.dylib', build/'grdb/GRDB.swiftmodule']
record = {**inputs, 'binary_and_grdb': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, 'swift_version': subprocess.check_output(['swiftc', '--version'], text=True), 'compile_admission': 'lr-lease heavy, lockf heavy.lock, 8 GiB floor on df -k /'}
(build/'build-record.json').write_text(json.dumps(record, sort_keys=True, separators=(',', ':')) + '\n')
PY
"$build_dir/reverse-meal-runner" "$1" "$2" --result "$4"
