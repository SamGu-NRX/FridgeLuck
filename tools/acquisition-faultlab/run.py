"""Drive the PR41 acquisition adapter against every faultlab scenario.

For each scenario this runner:
  1. loads a FRESH copy of the production adapter module,
  2. points its module constants at a per-scenario temp cache dir and this
     lab's loopback server (adapter-shaped URLs: /imagery/<scenario>/...),
  3. replicates the adapter's own main() skip-then-fetch flow (done_keys +
     fetch), including stale-cache preseeding declared by the scenario,
  4. records what the adapter did: attempts, statuses, adapter verdict,
     and the exact bytes that landed on disk (size + sha256).

The runner measures; it does not judge the adapter. The only hard gate is
the clean control: if the adapter cannot download the fault-free scenario
byte-exactly, the environment is broken and the run aborts (exit 2).

Usage:
    python3 run.py [--adapter PATH] [--out results.json]
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import time
import types
from pathlib import Path

LAB = Path(__file__).resolve().parent
REPO_ROOT = LAB.parents[1]
sys.path.insert(0, str(LAB))

import fixture_server  # noqa: E402
from fixture_server import FaultServer, sha256_hex, synthetic_content  # noqa: E402


def load_scenarios() -> dict:
    return json.loads((LAB / "scenarios.json").read_text())

DEFAULT_ADAPTER = REPO_ROOT / "experiments" / "nutrition5k-portion" / "src" / "download_imagery.py"


def fname_for(scenario: dict) -> str:
    return "depth_raw.png" if "depth" in scenario["id"] else "rgb.png"


def fresh_adapter(adapter_path: Path, token: str):
    """Load a pristine copy of the adapter module (no cross-scenario state)."""
    spec = importlib.util.spec_from_file_location(f"adapter_{token}", adapter_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _NoSleep(types.ModuleType):
    """Stand-in for the adapter's `time` module: keep time(), drop sleeps so
    retry pacing does not dominate the measurement (pacing is static code)."""

    def __init__(self, real):
        super().__init__("time")
        self._real = real

    def sleep(self, seconds):  # noqa: D102
        return

    def time(self):  # noqa: D102
        return self._real.time()


def preseed(scenario: dict, mod, tmp: Path) -> dict:
    """Apply the scenario's declared cache preseeding. Returns preseed facts."""
    mode = scenario.get("harness", {}).get("preseed")
    facts: dict = {"mode": mode}
    if mode is None:
        return facts
    content = synthetic_content(scenario["content"]["seed"], scenario["content"]["size"])
    dish, fname = scenario["dish_id"], fname_for(scenario)
    out_path = mod.IMAGERY_DIR / dish / fname
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if mode == "stale_manifest_ok":
        # A previous run left a truncated file on disk while the manifest
        # claims a successful download with the correct digest.
        partial = content[:512]
        out_path.write_bytes(partial)
        with mod.MANIFEST.open("w") as fh:
            fh.write(json.dumps({
                "dish_id": dish, "file": fname, "bytes": len(partial),
                "sha256": sha256_hex(content), "status": "ok", "ms": 12,
            }) + "\n")
        facts["disk_before_bytes"] = len(partial)
        facts["manifest_claims_sha256"] = sha256_hex(content)
    elif mode == "partial_file":
        # A previous run crashed mid-download; no manifest entry exists.
        partial = content[:1024]
        out_path.write_bytes(partial)
        facts["disk_before_bytes"] = len(partial)
    else:
        raise ValueError(f"unknown preseed mode {mode!r}")
    return facts


def measure_scenario(scn: dict, srv: FaultServer, adapter_path: Path) -> dict:
    token = hashlib.sha1(scn["id"].encode()).hexdigest()[:10]
    mod = fresh_adapter(adapter_path, token)
    mod.time = _NoSleep(time)  # type: ignore[assignment]
    mod.BASE = f"http://127.0.0.1:{srv.port}/imagery/{scn['id']}"
    tmp = Path(tempfile.mkdtemp(prefix="faultlab-"))
    mod.IMAGERY_DIR = tmp / "imagery"
    mod.MANIFEST = tmp / "manifest.jsonl"
    mod.AVAILABILITY = tmp / "availability.json"

    fname = fname_for(scn)
    preseed_facts = preseed(scn, mod, tmp)

    # Replicate the adapter main() flow: skip keys already marked ok, else fetch.
    if (scn["dish_id"], fname) in mod.done_keys():
        result = {"dish_id": scn["dish_id"], "file": fname, "bytes": None,
                  "sha256": None, "ms": 0, "status": "skipped (cached)"}
    else:
        result = mod.fetch(scn["dish_id"], fname)

    log = srv.requests_for(scn["id"])
    out_path = mod.IMAGERY_DIR / scn["dish_id"] / fname
    disk = out_path.read_bytes() if out_path.exists() else None

    measurement = {
        "scenario_id": scn["id"],
        "fault": scn["fault"],
        "preseed": preseed_facts,
        "request": {"dish_id": scn["dish_id"], "fname": fname},
        "attempts": len(log),
        "server_statuses": [r["status"] for r in log],
        "server_ends": [r["end"] for r in log],
        "any_range_header": any(r["range"] for r in log),
        "adapter": {"status": result["status"], "bytes": result.get("bytes"),
                    "sha256": result.get("sha256"), "ms": result.get("ms")},
        "disk": {"written": disk is not None,
                 "bytes": len(disk) if disk is not None else None,
                 "sha256": sha256_hex(disk) if disk is not None else None},
        "expect": {
            "content_size": scn["expect"]["content_size"],
            "content_sha256": scn["expect"]["content_sha256"],
            "served_size": scn["expect"]["served_size"],
            "served_sha256": scn["expect"]["served_sha256"],
        },
        "derived": {
            "disk_matches_expected_content":
                disk is not None and sha256_hex(disk) == scn["expect"]["content_sha256"],
            "disk_matches_expected_served":
                disk is not None and sha256_hex(disk) == scn["expect"]["served_sha256"],
        },
    }
    shutil.rmtree(tmp, ignore_errors=True)
    return measurement


def main() -> int:
    ap = argparse.ArgumentParser(description="Faultlab adapter measurement run")
    ap.add_argument("--adapter", type=Path, default=DEFAULT_ADAPTER)
    ap.add_argument("--out", type=Path, default=LAB / "results.json")
    args = ap.parse_args()

    adapter_path = args.adapter.resolve()
    if not adapter_path.exists():
        print(f"adapter not found: {adapter_path}", file=sys.stderr)
        return 1

    # Every urllib request in this process must fail fast on non-loopback URLs.
    fixture_server.install_loopback_opener()

    def git(*argv: str) -> str:
        return subprocess.run(["git", *argv], cwd=REPO_ROOT, capture_output=True,
                              text=True, check=True).stdout.strip()

    manifest = load_scenarios()
    scenarios = manifest["scenarios"]
    results = {
        "run": {
            "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "python": sys.version.split()[0],
            "adapter_path": str(adapter_path),
            "adapter_sha256": sha256_hex(adapter_path.read_bytes()),
            "repo_head": git("rev-parse", "HEAD"),
            "loopback_only": manifest["loopback_only"],
            "scenario_count": len(scenarios),
        },
        "scenarios": [],
    }

    with FaultServer(scenarios) as srv:
        results["run"]["server_bind"] = f"127.0.0.1:{srv.port}"
        for scn in scenarios:
            rec = measure_scenario(scn, srv, adapter_path)
            results["scenarios"].append(rec)
            if scn["id"] == "clean-rgb-control":  # the environment sanity gate
                ok = rec["derived"]["disk_matches_expected_content"]
                print(f"[{'ok' if ok else 'GATE-FAIL'}] {scn['id']}: "
                      f"{rec['adapter']['status']} attempts={rec['attempts']}")
                if not ok:
                    results["run"]["clean_control_gate"] = "FAILED"
                    args.out.write_text(json.dumps(results, indent=2) + "\n")
                    print("clean control failed to round-trip byte-exactly; "
                          "environment is broken - aborting (exit 2)", file=sys.stderr)
                    return 2
            else:
                print(f"[measured] {scn['id']}: {rec['adapter']['status']} "
                      f"attempts={rec['attempts']} "
                      f"disk={rec['disk']['bytes']}B "
                      f"sha_ok={rec['derived']['disk_matches_expected_content']}")

    results["run"]["clean_control_gate"] = "PASSED"
    args.out.write_text(json.dumps(results, indent=2) + "\n")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
