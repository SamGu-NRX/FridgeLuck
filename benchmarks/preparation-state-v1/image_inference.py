#!/usr/bin/env python3
"""Image-inference arm for preparation-state-v1.

Executes the CPU image baseline (open_clip CLIP ViT-B/32 laion2b_s34b_b79k,
deterministic crop schedule mirroring the app's ScanImagePreprocessor, app
label resolution) over the FROZEN FoodSeg103 validation slice pinned by
experiments/ingredient-recognition (commit 21fb744), then scores the
preparation-state questions on top of the resulting detections:

  - identity: are ground-truth ingredient groups detected on image?
  - state binding: when the image pipeline resolves an ingredient whose
    preparation-state group has >= 2 records (raw/cooked/...), the image
    carries NO state evidence — does the pipeline still bind a concrete
    stateful record? FoodSeg103 has no state labels, so state CORRECTNESS is
    unverifiable; what we measure is how often an ungrounded state choice is
    made at all, and (in nutrient_consequences.py) how much nutrition hangs
    on that choice.

The observation pass reuses the cached image-embedding tensor (pinned by the
ingredient-recognition benchmark) so this stays a CPU-scale run. Model weights
load from the local Hugging Face cache; no network is needed.

Run: python3 image_inference.py --out results/image_inference
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parent
REPO_ROOT = BENCH_ROOT.parents[1]

OBSERVE = REPO_ROOT / "experiments" / "ingredient-recognition" / "runner" / "observe.py"
IR_MANIFEST = REPO_ROOT / "experiments" / "ingredient-recognition" / "manifest.json"
TAXONOMY = REPO_ROOT / "experiments" / "ingredient-recognition" / "taxonomy" / "foodseg103_to_catalog.csv"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_observations(out_observations: Path) -> None:
    cmd = [
        sys.executable, str(OBSERVE),
        "--split", "validation",
        "--label-space", "curated+usda",
        "--absorbers", "on",
        "--out", str(out_observations),
    ]
    print("+", " ".join(cmd))
    t0 = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True)
    tail = "\n".join((result.stdout + result.stderr).splitlines()[-6:])
    if result.returncode != 0:
        sys.stderr.write(tail)
        raise SystemExit(f"observation runner failed with exit {result.returncode}")
    print(tail)
    print(f"observations written in {time.time() - t0:.0f}s")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(BENCH_ROOT / "results" / "image_inference"))
    ap.add_argument("--skip-runner", action="store_true",
                    help="reuse existing observations.jsonl.gz instead of re-running")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    observations_path = out / "observations.jsonl.gz"

    if not args.skip_runner:
        run_observations(observations_path)

    prep = json.loads((BENCH_ROOT / "manifest.json").read_text())
    id_to_group: dict[int, str] = {}
    id_stateful: dict[int, bool] = {}
    multi_member_groups: set[str] = set()
    for g in prep["groups"]:
        if len(g["members"]) >= 2:
            multi_member_groups.add(g["group_id"])
        for m in g["members"]:
            id_to_group[m["catalog_id"]] = g["group_id"]
            id_stateful[m["catalog_id"]] = bool(m["states"])

    taxonomy: dict[int, dict] = {}
    with TAXONOMY.open(newline="") as f:
        for row in csv.DictReader(f):
            ids = [int(x) for x in re.split(r"[,;]", row["target_ingredient_ids"]) if x.strip()]
            taxonomy[int(row["class_id"])] = {
                "kind": row["semantic_kind"],
                "catalog_ids": ids,
                "class_name": row["class_name_normalized"],
            }

    ir = json.loads(IR_MANIFEST.read_text())
    validation_images = [im for im in ir["images"] if im["split"] == "validation"]

    with gzip.open(observations_path, "rt") as f:
        obs_by_image: dict[int, dict] = {}
        for line in f:
            rec = json.loads(line)
            obs_by_image[int(rec["image_id"])] = rec

    predictions_path = out / "image_predictions.jsonl"
    n_expected_images = 0
    expected_groups_total = 0
    expected_groups_detected = 0
    images_any_hit = 0
    spurious_group_detections = 0
    ambiguous_group_overlaps = 0
    stateful_bindings_multi = 0
    stateless_bindings_multi = 0
    stateful_bindings_single = 0
    multi_member_groups_bound = set()
    curated_detections = 0

    with predictions_path.open("w") as f:
        for im in validation_images:
            img_id = int(im["image_id"])
            class_ids = [int(c) for c in str(im["classes_on_image"]).split(",") if c.strip() and c != "0"]
            expected_exact, expected_coarse, ambiguous = set(), set(), set()
            for cid in class_ids:
                t = taxonomy.get(cid)
                if not t:
                    continue
                groups = {id_to_group[i] for i in t["catalog_ids"] if i in id_to_group}
                if t["kind"] == "exact":
                    expected_exact |= groups
                elif t["kind"] == "coarse":
                    expected_coarse |= groups
                elif t["kind"] == "ambiguous":
                    ambiguous |= groups
            expected_all = expected_exact | expected_coarse

            obs = obs_by_image.get(img_id)
            detections = []
            if obs:
                for det in obs.get("detections", []):
                    rid = det["ingredient_id"]
                    gid = id_to_group.get(rid)
                    stateful = id_stateful.get(rid, False)
                    if gid is None:
                        curated_detections += 1
                    detections.append({
                        "ingredient_id": rid,
                        "group_id": gid,
                        "stateful": stateful,
                        "confidence": det["confidence"],
                    })
                    if gid in multi_member_groups:
                        if stateful:
                            stateful_bindings_multi += 1
                            multi_member_groups_bound.add(gid)
                        else:
                            stateless_bindings_multi += 1
                    elif gid is not None and stateful:
                        stateful_bindings_single += 1

            detected_groups = {d["group_id"] for d in detections if d["group_id"]}
            hit = detected_groups & expected_all
            spurious_group_detections += len(detected_groups - expected_all)
            ambiguous_group_overlaps += len(detected_groups & ambiguous)

            n_expected_images += 1
            expected_groups_total += len(expected_all)
            expected_groups_detected += len(hit)
            images_any_hit += 1 if hit else 0

            f.write(json.dumps({
                "image_id": img_id,
                "expected_groups_exact": sorted(expected_exact),
                "expected_groups_coarse": sorted(expected_coarse),
                "ambiguous_groups": sorted(ambiguous),
                "detections": detections,
            }, sort_keys=True) + "\n")

    metrics = {
        "validation_images": len(validation_images),
        "images_with_expected_groups": n_expected_images,
        "images_any_expected_group_detected": images_any_hit,
        "expected_groups": expected_groups_total,
        "expected_groups_detected": expected_groups_detected,
        "group_detection_recall": round(expected_groups_detected / expected_groups_total, 4) if expected_groups_total else None,
        "image_any_hit_rate": round(images_any_hit / n_expected_images, 4) if n_expected_images else None,
        "spurious_group_detections": spurious_group_detections,
        "ambiguous_group_overlaps": ambiguous_group_overlaps,
        "curated_space_detections": curated_detections,
        "state_binding": {
            "multi_member_group_detections": stateful_bindings_multi + stateless_bindings_multi,
            "stateful_binding_ungrounded": stateful_bindings_multi,
            "stateful_binding_rate_on_multi": round(
                stateful_bindings_multi / (stateful_bindings_multi + stateless_bindings_multi), 4
            ) if (stateful_bindings_multi + stateless_bindings_multi) else None,
            "multi_member_groups_with_binding": len(multi_member_groups_bound),
            "single_member_group_stateful_bindings": stateful_bindings_single,
            "note": (
                "FoodSeg103 has no preparation-state labels, so state correctness is "
                "unverifiable on image. stateful_binding_ungrounded counts detections on "
                "multi-alternative groups that bound a concrete stateful record with no "
                "image evidence for that state."
            ),
        },
    }

    import open_clip
    import torch
    report = {
        "arm": "image_inference",
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "environment": {
            "model": "ViT-B-32",
            "pretrained": "laion2b_s34b_b79k",
            "open_clip": getattr(open_clip, "__version__", "unknown"),
            "torch": torch.__version__,
            "device": "cpu",
            "split": "validation",
            "label_space": "curated+usda",
            "absorbers": "on",
        },
        "inputs": {
            "observations_sha256": sha256_file(observations_path),
            "ingredient_recognition_manifest_sha256": sha256_file(IR_MANIFEST),
            "taxonomy_sha256": sha256_file(TAXONOMY),
            "preparation_state_manifest_sha256": sha256_file(BENCH_ROOT / "manifest.json"),
        },
        "predictions_sha256": sha256_file(predictions_path),
        "metrics": metrics,
    }
    (out / "image_report.json").write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    print(json.dumps(metrics, indent=1))
    print(f"wrote {predictions_path} and {out / 'image_report.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
