#!/usr/bin/env python3
"""Run a scoring arm over the frozen nonfood-rejection-v1 manifest.

An "arm" is a Python module exposing:

    ARM_NAME = "my-arm"                      # optional, defaults to filename
    def evaluate(image_path, record) -> dict with keys:
        food_score     float in [0, 1] — pipeline food-evidence score
        produced_food  bool — did the pipeline produce >=1 food label that
                       resolved to an ingredient through the base resolver
        food_labels    list[str] — raw produced labels (recorded verbatim)

Usage:
    python3 run.py --arm arms/my_arm.py \
        [--manifest manifest.json] [--cache-dir $NONFOOD_CACHE] \
        [--out reports/raw/my-arm.json] [--limit N]

The report pins the manifest by sha256 (the scorer rejects reports whose
hash no longer matches) and records, per image, the raw arm output plus the
manifest's stratum/split/group/pair fields. The scorer (score.py) turns raw
reports into verdicts and metrics; run.py itself never scores.

Determinism: the same manifest, cache, and arm module must produce a
byte-identical report. Arms that call an external service must pin a model
or service version in the report themselves.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_arm(arm_path: Path):
    spec = importlib.util.spec_from_file_location("bench_arm", arm_path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load arm module from {arm_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if not hasattr(mod, "evaluate"):
        raise SystemExit(f"arm {arm_path} does not expose evaluate(image_path, record)")
    name = getattr(mod, "ARM_NAME", arm_path.stem)
    version = getattr(mod, "ARM_VERSION", "unversioned")
    return name, version, mod.evaluate


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--arm", required=True, help="path to an arm module exposing evaluate()")
    ap.add_argument("--manifest", default=str(HERE / "manifest.json"))
    ap.add_argument("--cache-dir", default=os.environ.get("NONFOOD_CACHE"),
                    help="image cache root with images/<subset>/<image_id>.jpg")
    ap.add_argument("--out", default=None, help="report path (default reports/raw/<arm-name>.json)")
    ap.add_argument("--limit", type=int, default=None, help="evaluate only the first N images (smoke runs)")
    args = ap.parse_args()

    if not args.cache_dir:
        raise SystemExit("--cache-dir or NONFOOD_CACHE is required (images are not committed)")
    manifest_bytes = Path(args.manifest).read_bytes()
    manifest = json.loads(manifest_bytes)
    arm_name, arm_version, evaluate = load_arm(Path(args.arm))

    cache = Path(args.cache_dir)
    results = []
    records = manifest["images"]
    if args.limit:
        records = records[: args.limit]
    for r in records:
        img_path = cache / "images" / r["subset"] / f"{r['image_id']}.jpg"
        if not img_path.exists():
            raise SystemExit(f"missing cached image {img_path}")
        out = evaluate(img_path, r)
        results.append({
            "image_id": r["image_id"],
            "stratum": r["stratum"],
            "split": r["split"],
            "group_id": r["group_id"],
            "series_id": r["series_id"],
            "pair_id": r["pair_id"],
            "food_score": float(out["food_score"]),
            "produced_food": bool(out["produced_food"]),
            "food_labels": list(out.get("food_labels", [])),
        })

    report = {
        "arm": {"name": arm_name, "version": arm_version, "path": str(args.arm)},
        "manifest_name": manifest["meta"]["name"],
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "images": results,
    }
    out_path = Path(args.out) if args.out else HERE / "reports" / "raw" / f"{arm_name}.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=1))
    print(f"wrote {out_path} ({len(results)} images)")


if __name__ == "__main__":
    main()
