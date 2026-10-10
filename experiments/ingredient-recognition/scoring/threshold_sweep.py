#!/usr/bin/env python3
"""Threshold sweep on development data only.

Reads a development observation file produced by runner/observe.py with
--record-floor well below any candidate threshold (crop labels carry
classifier probabilities), re-derives detections at each candidate
threshold using the app's rules (confidence > T, resolver pass, absorber
skip, best-per-ingredient dedup), and scores each threshold with the same
definitions as score.py (instance recall / detection precision).

The chosen threshold maximizes detection F1 on the development run. The
app's shipped constant (0.1) is reported for reference. The frozen choice
is written to scoring/thresholds.json; final evaluation runs must use it.

Authoring-name replay is not involved: the dev file comes from real image
embeddings only.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
from collections import Counter, defaultdict
from pathlib import Path

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent


def load_taxonomy() -> dict[int, dict]:
    taxonomy = {}
    with (EXPERIMENT_ROOT / "taxonomy" / "foodseg103_to_catalog.csv").open() as f:
        for row in csv.DictReader(f):
            taxonomy[int(row["class_id"])] = {
                "targets": [int(t) for t in row["target_ingredient_ids"].split(";") if t],
            }
    return taxonomy


def derive_detections(rec: dict, threshold: float) -> list[int]:
    """App rules re-applied at threshold from floor-recorded crop labels."""
    best: dict[int, float] = {}
    for crop in rec["crops"]:
        for label in crop["labels"]:
            if label["is_absorber"]:
                continue
            prob = label["prob"]
            rid = label["resolved_id"]
            if prob > threshold and rid is not None:
                if rid not in best or prob > best[rid]:
                    best[rid] = prob
    return list(best)


def score(gt: dict[int, list[int]], detections: dict[int, list[int]], taxonomy: dict[int, dict]) -> dict:
    inst_total = 0
    inst_hit = 0
    det_total = 0
    det_correct = 0
    abstain = 0
    for image_id, classes in gt.items():
        target_sets = [set(taxonomy[c]["targets"]) for c in classes if taxonomy[c]["targets"]]
        dets = set(detections.get(image_id, []))
        if not target_sets:
            continue
        if not dets:
            abstain += 1
        covered: set[int] = set()
        for targets in target_sets:
            inst_total += 1
            if dets & targets:
                inst_hit += 1
                covered |= targets
        for d in dets:
            det_total += 1
            if d in covered:
                det_correct += 1
    recall = inst_hit / inst_total if inst_total else 0.0
    precision = det_correct / det_total if det_total else 0.0
    f1 = 2 * recall * precision / (recall + precision) if recall + precision else 0.0
    return {
        "instance_recall": round(recall, 4),
        "detection_precision": round(precision, 4),
        "detection_f1": round(f1, 4),
        "instances": inst_total,
        "detections": det_total,
        "abstain_images": abstain,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--observations", required=True, help="development .jsonl.gz from observe.py")
    ap.add_argument("--split", default="train")
    ap.add_argument("--manifest", default=str(EXPERIMENT_ROOT / "manifest.json"))
    ap.add_argument("--thresholds", default="0.05,0.1,0.15,0.2,0.25,0.3,0.4,0.5")
    ap.add_argument("--out", default=str(EXPERIMENT_ROOT / "scoring" / "thresholds.json"))
    args = ap.parse_args()

    taxonomy = load_taxonomy()
    manifest = json.loads(Path(args.manifest).read_text())
    gt: dict[int, list[int]] = {}
    for row in manifest["images"]:
        if row["split"] != args.split:
            continue
        gt[int(row["image_id"])] = [int(c) for c in row["classes_on_image"].split(",") if c]

    records: dict[int, dict] = {}
    with gzip.open(args.observations, "rt") as f:
        for line in f:
            rec = json.loads(line)
            records[rec["image_id"]] = rec

    # score only images this development run actually observed
    gt = {img_id: classes for img_id, classes in gt.items() if img_id in records}

    thresholds = [float(t) for t in args.thresholds.split(",")]
    table = []
    for t in thresholds:
        dets = {img_id: derive_detections(rec, t) for img_id, rec in records.items()}
        row = {"threshold": t, **score(gt, dets, taxonomy)}
        table.append(row)
        print(row)

    best = max(table, key=lambda r: r["detection_f1"])
    out = {
        "dev_observations": args.observations,
        "dev_split": args.split,
        "dev_images": len(records),
        "criterion": "max detection F1 on development data",
        "app_reference_threshold": 0.1,
        "chosen_threshold": best["threshold"],
        "sweep": table,
        "note": (
            "Threshold developed on the train-split development run only; the "
            "validation split was never touched during selection. Final runs "
            "use chosen_threshold frozen here."
        ),
    }
    Path(args.out).write_text(json.dumps(out, indent=1) + "\n")
    print(f"chosen threshold: {best['threshold']} -> {args.out}")


if __name__ == "__main__":
    main()
