"""Extract frozen-policy features from downloaded Nutrition5k overhead imagery.

Reads dish_targets.csv + the downloader manifest, computes RGB features for
every dish with a fetched rgb.png and RGB+D features where depth_raw.png was
also fetched, and stores one .npz. Fully deterministic; parallel across files.

Also records per-image extraction wall time (single-worker timing loop on a
sample) -- the local per-plate inference cost, with model predict time
measured separately in evaluate.py.
"""

from __future__ import annotations

import csv
import json
import os
import platform
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from features import DEPTH_FEATURE_NAMES, RGB_FEATURE_NAMES, depth_features, rgb_features  # noqa: E402

IMAGERY = Path("/home/user/work/n5k-data/imagery")
MANIFEST = Path("/home/user/work/n5k-data/imagery_manifest.jsonl")
TABLE = Path(__file__).resolve().parents[1] / "data" / "dish_targets.csv"
OUT_NPZ = Path("/home/user/work/n5k-data/features.npz")
OUT_STATS = Path("/home/user/work/n5k-data/extraction_stats.json")
WORKERS = 8


def ok_files() -> dict[str, set[str]]:
    ok: dict[str, set[str]] = {}
    with MANIFEST.open() as fh:
        for line in fh:
            rec = json.loads(line)
            if rec["status"] == "ok":
                ok.setdefault(rec["dish_id"], set()).add(rec["file"])
    return ok


def one(dish_id: str, files: set[str]) -> dict:
    rgb = Image.open(IMAGERY / dish_id / "rgb.png")
    frgb = rgb_features(rgb)
    fdepth = None
    if "depth_raw.png" in files:
        # The bucket contains a few 0-byte/unopenable depth files (observed:
        # dish_1564159636); an unopenable depth counts as depth-unavailable.
        try:
            fdepth = depth_features(Image.open(IMAGERY / dish_id / "depth_raw.png"), rgb)
        except Exception:  # noqa: BLE001 - degraded depth is an availability fact
            fdepth = None
    return {"dish_id": dish_id, "rgb": frgb, "depth": fdepth}


def main() -> int:
    ok = ok_files()
    ids: list[str] = []
    with TABLE.open() as fh:
        for row in csv.DictReader(fh):
            if "rgb.png" in ok.get(row["dish_id"], set()):
                ids.append(row["dish_id"])
    ids.sort()
    print(f"extracting features for {len(ids)} dishes", flush=True)

    results = {}
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for i, res in enumerate(pool.map(lambda d: one(d, ok[d]), ids)):
            results[res["dish_id"]] = res
            if (i + 1) % 500 == 0:
                print(f"progress {i+1}/{len(ids)}", flush=True)

    n_depth = sum(1 for r in results.values() if r["depth"] is not None)
    rgb_mat = np.stack([results[d]["rgb"] for d in ids])
    depth_mat = np.full((len(ids), len(DEPTH_FEATURE_NAMES)), np.nan)
    for i, d in enumerate(ids):
        if results[d]["depth"] is not None:
            depth_mat[i] = results[d]["depth"]
    np.savez_compressed(
        OUT_NPZ, dish_ids=np.array(ids), rgb=rgb_mat, depth=depth_mat,
        rgb_names=np.array(RGB_FEATURE_NAMES), depth_names=np.array(DEPTH_FEATURE_NAMES),
    )

    # Single-thread timing sample (first 40 dishes): honest local cost measurement.
    t0 = time.time()
    n_timed = min(40, len(ids))
    for d in ids[:n_timed]:
        one(d, ok[d])
    per_image_ms = (time.time() - t0) * 1000 / n_timed

    env = {
        "python": platform.python_version(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "processor": platform.processor() or platform.machine(),
        "numpy": np.__version__,
        "pillow": Image.__version__,
        "per_image_feature_ms_single_thread": round(per_image_ms, 1),
        "n_rgb": len(ids),
        "n_rgb_and_depth": n_depth,
        "rgb_feature_dim": int(rgb_mat.shape[1]),
        "depth_feature_dim": int(depth_mat.shape[1]),
        "nan_depth_fraction": float(np.isnan(depth_mat[:, 0]).mean()),
    }
    OUT_STATS.write_text(json.dumps(env, indent=2))
    print(json.dumps(env, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
