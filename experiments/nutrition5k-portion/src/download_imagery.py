"""Selective Nutrition5k imagery downloader with a resumable hashing manifest.

Downloads only overhead rgb.png (dishes with an official RGB split) and
depth_raw.png (dishes with an official depth split) from the public bucket.
Camera-roll/side-angle videos are deliberately NOT downloaded: the frozen view
policy for this experiment is the calibrated overhead RGB-D view only.

availability.json (a full bucket listing) gates the job list: ~30% of dishes
have no overhead imagery at all (early-2019 IDs); their 404s are permanent and
are neither retried nor counted as transient failures.

Records per file: bytes, sha256, fetch latency, HTTP status -> manifest JSONL.
Resumable: skips (dish_id, file) pairs already recorded as ok.
"""

from __future__ import annotations

import csv
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BASE = "https://storage.googleapis.com/nutrition5k_dataset/nutrition5k_dataset/imagery/realsense_overhead"
IMAGERY_DIR = Path("/home/user/work/n5k-data/imagery")
MANIFEST = Path("/home/user/work/n5k-data/imagery_manifest.jsonl")
TABLE = Path(__file__).resolve().parents[1] / "data" / "dish_targets.csv"
AVAILABILITY = Path("/home/user/work/n5k-data/availability.json")
WORKERS = 12
RETRIES = 4


def load_todo() -> list[tuple[str, str]]:
    availability: dict[str, set[str]] = {
        d: set(v) for d, v in json.loads(AVAILABILITY.read_text()).items()
    }
    jobs: list[tuple[str, str]] = []
    with TABLE.open() as fh:
        for row in csv.DictReader(fh):
            dish = row["dish_id"]
            files = availability.get(dish, set())
            if row["official_rgb_split"] in ("train", "test") and "rgb.png" in files:
                jobs.append((dish, "rgb.png"))
            if row["official_depth_split"] in ("train", "test") and "depth_raw.png" in files:
                jobs.append((dish, "depth_raw.png"))
    return jobs


def done_keys() -> set[tuple[str, str]]:
    if not MANIFEST.exists():
        return set()
    keys = set()
    with MANIFEST.open() as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("status") == "ok":
                keys.add((rec["dish_id"], rec["file"]))
    return keys


def fetch(dish_id: str, fname: str) -> dict:
    url = f"{BASE}/{dish_id}/{fname}"
    out_dir = IMAGERY_DIR / dish_id
    out_path = out_dir / fname
    t0 = time.time()
    last_err = None
    for attempt in range(RETRIES):
        try:
            with urllib.request.urlopen(url, timeout=120) as resp:
                data = resp.read()
            h = hashlib.sha256(data).hexdigest()
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path.write_bytes(data)
            return {
                "dish_id": dish_id,
                "file": fname,
                "bytes": len(data),
                "sha256": h,
                "ms": round((time.time() - t0) * 1000),
                "status": "ok",
            }
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return {
                    "dish_id": dish_id,
                    "file": fname,
                    "bytes": None,
                    "sha256": None,
                    "ms": round((time.time() - t0) * 1000),
                    "status": "missing (404)",
                }
            last_err = f"{type(exc).__name__}: {exc}"
            time.sleep(1.5 * (attempt + 1))
        except Exception as exc:  # noqa: BLE001 - record and retry
            last_err = f"{type(exc).__name__}: {exc}"
            time.sleep(1.5 * (attempt + 1))
    return {
        "dish_id": dish_id,
        "file": fname,
        "bytes": None,
        "sha256": None,
        "ms": round((time.time() - t0) * 1000),
        "status": f"error: {last_err}",
    }


def main() -> int:
    jobs = load_todo()
    already = done_keys()
    todo = [j for j in jobs if j not in already]
    print(f"jobs={len(jobs)} done={len(already)} todo={len(todo)}", flush=True)
    t0 = time.time()
    ok = err = 0
    with MANIFEST.open("a") as mfh, ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for i, rec in enumerate(pool.map(lambda j: fetch(*j), todo)):
            if rec["status"] == "ok":
                ok += 1
            else:
                err += 1
                print(f"ERROR {rec['dish_id']}/{rec['file']}: {rec['status']}", flush=True)
            mfh.write(json.dumps(rec) + "\n")
            if (i + 1) % 250 == 0:
                rate = (i + 1) / max(time.time() - t0, 1e-9)
                print(f"progress {i+1}/{len(todo)} ok={ok} err={err} rate={rate:.1f}/s", flush=True)
    print(f"DONE ok={ok} err={err} elapsed={time.time()-t0:.0f}s", flush=True)
    return 0 if err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
