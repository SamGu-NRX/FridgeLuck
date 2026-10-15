#!/usr/bin/env bash
# Pins a completed live-production replay run: sha256 of the built executable
# and of the replay output rows, alongside the source pin (RealManifest.json,
# written by refresh.sh). The record is what verify_production.py checks the
# committed runs/production_replay.jsonl against.
#
# Usage: bash Scripts/pin_run.sh <path-to-executable> <path-to-replay-jsonl>
set -euo pipefail
cd "$(dirname "$0")/.."

exec_path="${1:-.build/debug/PantryFeasibilityProduction}"
out_path="${2:?usage: pin_run.sh <executable> <replay-output.jsonl>}"

[ -f "$exec_path" ] || { echo "missing executable: $exec_path" >&2; exit 1; }
[ -f "$out_path" ] || { echo "missing replay output: $out_path" >&2; exit 1; }

exec_hash=$(sha256sum "$exec_path" | awk '{print $1}')
out_hash=$(sha256sum "$out_path" | awk '{print $1}')
rows=$(wc -l < "$out_path" | tr -d ' ')

record="../runs/production_run_record.json"
mkdir -p ../runs
python3 - "$record" "$exec_hash" "$out_hash" "$rows" <<'PY'
import json
import pathlib
import sys

record_path = pathlib.Path(sys.argv[1])
exec_hash, out_hash, rows = sys.argv[2], sys.argv[3], sys.argv[4]

real_manifest = {}
manifest_path = pathlib.Path("RealManifest.json")
if manifest_path.is_file():
    real_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

record_path.write_text(json.dumps({
    "executable": ".build/debug/PantryFeasibilityProduction",
    "executable_sha256": exec_hash,
    "replay_output": "runs/production_replay.jsonl",
    "replay_output_sha256": out_hash,
    "replay_rows": int(rows),
    "toolchain": real_manifest.get("toolchain", ""),
    "source_pin": "production/RealManifest.json",
    "build": real_manifest.get("build", "swift build -Xswiftc -DSQLITE_DISABLE_SNAPSHOT"),
    "note": (
        "pins the live production replay: sha256 of the built executable and "
        "of the committed replay rows; verify_production.py checks the rows "
        "against this record"),
}, indent=1) + "\n", encoding="utf-8")
PY

echo "pinned run -> $record (executable $exec_hash, output $out_hash, $rows rows)"
