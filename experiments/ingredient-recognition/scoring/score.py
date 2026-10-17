#!/usr/bin/env python3
"""Score open-model observations against the taxonomy-mapped FoodSeg103 ground truth.

Definitions (documented in the report):
- GT instance: (image, FoodSeg103 class) with a semantic mapping target set in
  taxonomy/foodseg103_to_catalog.csv. Instances of unsupported classes have no
  target; they are scored as "no-claim" (see below) and excluded from recall.
- Detection: one app-pipeline observation (resolved ingredient id) per image.
  A detection is CORRECT if its id is in the target set of some GT class of
  that image (exact, coarse, and ambiguous targets all count; the target set
  for ambiguous classes is the union of its candidates).
- Instance recall: fraction of GT instances whose target set intersects the
  image's detections. Ambiguous instances credit any of their candidates.
- Detection precision: correct detections / all detections.
- Unjustified detections: detections whose id matches no GT class target —
  includes false positives AND real foods the GT omits (annotation
  incompleteness); reported separately, never silently counted as errors.
- Abstention: images with >= 1 mapped GT class but zero detections.
- No-claim discipline: for images whose GT classes are ALL unsupported, the
  correct behavior is zero detections; images where the pipeline still emits
  something are counted as no-claim violations.

Outputs: scoring/<run>_scores.json + scoring/<run>_per_class.csv
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
                "name": row["class_name_normalized"],
                "kind": row["semantic_kind"],
                "targets": [int(t) for t in row["target_ingredient_ids"].split(";") if t],
            }
    return taxonomy


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--observations", required=True, help="observations .jsonl.gz")
    ap.add_argument("--split", default="validation")
    ap.add_argument("--manifest", default=str(EXPERIMENT_ROOT / "manifest.json"))
    ap.add_argument("--id2label", default=str(EXPERIMENT_ROOT / "taxonomy" / "foodseg103_id2label.json"))
    ap.add_argument("--out-prefix", default="")
    ap.add_argument("--out-dir", default=str(EXPERIMENT_ROOT / "scoring"))
    args = ap.parse_args()

    taxonomy = load_taxonomy()
    id2label = json.loads(Path(args.id2label).read_text())

    # mapping coverage from the taxonomy itself
    n_classes = len(taxonomy)
    by_kind = Counter(t["kind"] for t in taxonomy.values())
    n_with_targets = sum(1 for t in taxonomy.values() if t["targets"])

    # ground truth per image: {image_id: [class_id,...]}
    manifest = json.loads(Path(args.manifest).read_text())
    gt: dict[int, list[int]] = {}
    for row in manifest["images"]:
        if row["split"] != args.split:
            continue
        gt[int(row["image_id"])] = [int(c) for c in row["classes_on_image"].split(",") if c]

    # detections per image
    detections: dict[int, list[dict]] = {}
    n_records = 0
    with gzip.open(args.observations, "rt") as f:
        for line in f:
            rec = json.loads(line)
            if not isinstance(rec, dict) or "image_id" not in rec or "detections" not in rec:
                raise SystemExit(
                    f"{args.observations}: malformed observation record (missing "
                    f"image_id or detections); refusing to score a partial run"
                )
            detections[rec["image_id"]] = rec["detections"]
            n_records += 1

    # observation-time failures recorded by runner/observe.py, if present
    failures_path = Path(args.observations).with_suffix("").with_suffix(".failures.jsonl")
    observation_failures: list[dict] = []
    if failures_path.exists():
        for line in failures_path.read_text().splitlines():
            if line.strip():
                observation_failures.append(json.loads(line))

    # ---- instance scoring
    inst_total = Counter()      # per kind: GT instances with targets
    inst_hit = Counter()        # per kind: recalled instances
    inst_unsupported = 0        # GT instances of unsupported classes (no targets)
    per_class = defaultdict(lambda: {"instances": 0, "hits": 0, "detections_credit": 0})
    det_total = 0
    det_correct = 0
    det_by_provenance = Counter()
    unjustified: list[dict] = []
    abstain_images = 0
    no_claim_images = 0
    no_claim_violations = 0
    per_image: list[dict] = []

    for image_id, classes in gt.items():
        target_sets = []
        all_unsupported = bool(classes)
        for cid in classes:
            meta = taxonomy[cid]
            if meta["targets"]:
                all_unsupported = False
                target_sets.append((cid, set(meta["targets"]), meta["kind"]))
            else:
                inst_unsupported += 1
        dets = detections.get(image_id, [])
        det_ids = {d["ingredient_id"] for d in dets}

        if not target_sets:
            if all_unsupported:
                no_claim_images += 1
                if dets:
                    no_claim_violations += 1
            per_image.append(
                {
                    "image_id": image_id,
                    "gt_class_ids": classes,
                    "outcome": "no_claim" if all_unsupported else "no_mapped_gt",
                    "detections": [d["ingredient_id"] for d in dets],
                    "correct_detections": [],
                }
            )
            continue

        if not dets:
            abstain_images += 1

        covered: set[int] = set()
        for cid, targets, kind in target_sets:
            inst_total[kind] += 1
            inst_total["all"] += 1
            per_class[cid]["instances"] += 1
            if det_ids & targets:
                inst_hit[kind] += 1
                inst_hit["all"] += 1
                per_class[cid]["hits"] += 1
                covered |= targets

        correct_dets = []
        for d in dets:
            det_total += 1
            ok = d["ingredient_id"] in covered
            if ok:
                det_correct += 1
                correct_dets.append(d["ingredient_id"])
                per_class[next(cid for cid, t, _ in target_sets if d["ingredient_id"] in t)]["detections_credit"] += 1
            else:
                if len(unjustified) < 400:
                    unjustified.append(
                        {
                            "image_id": image_id,
                            "ingredient_id": d["ingredient_id"],
                            "confidence": d["confidence"],
                            "original_label": d["original_label"],
                            "gt_classes": [taxonomy[c]["name"] for c in classes],
                        }
                    )
        per_image.append(
            {
                "image_id": image_id,
                "gt_class_ids": classes,
                "outcome": "abstain" if not dets else ("all_correct" if len(correct_dets) == len(dets) and correct_dets else "mixed" if correct_dets else "unjustified_only"),
                "detections": [d["ingredient_id"] for d in dets],
                "correct_detections": correct_dets,
            }
        )

    det_by_prov = Counter()
    for dets in detections.values():
        for d in dets:
            det_by_prov[d.get("provenance") or "catalog"] += 1

    recall = {k: (inst_hit[k] / inst_total[k] if inst_total[k] else None) for k in inst_total}
    precision = det_correct / det_total if det_total else 0.0

    det_resolved = sum(1 for d in detections.values() for d2 in d if d2.get("provenance"))
    scores = {
        "observations": args.observations,
        "split": args.split,
        "images_scored": len(gt),
        "images_with_detections": sum(1 for d in detections.values() if d),
        "instance_recall": recall,
        "instance_counts": dict(inst_total),
        "detection_precision": round(precision, 4),
        "detections_total": det_total,
        "detections_correct": det_correct,
        "detections_by_label_provenance": dict(det_by_prov),
        "abstain_images_with_mapped_gt": abstain_images,
        "no_claim_images": no_claim_images,
        "no_claim_violations": no_claim_violations,
        "unjustified_detections": det_total - det_correct,
        "unjustified_examples": unjustified[:60],
        "mapping_coverage": {
            "classes_total": n_classes,
            "classes_with_targets": n_with_targets,
            "classes_by_kind": dict(by_kind),
            "gt_instances_with_targets": inst_total.get("all", 0),
            "gt_instances_unsupported": inst_unsupported,
            "detections_with_resolved_provenance": det_resolved,
            "detections_total": det_total,
        },
        "observation_failures": observation_failures,
    }

    prefix = args.out_prefix or Path(args.observations).stem.replace(".jsonl", "").replace("openmodel_", "")
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{prefix}_scores.json").write_text(json.dumps(scores, indent=1))

    with gzip.open(out_dir / f"{prefix}_per_image.jsonl.gz", "wt") as f:
        for row in per_image:
            f.write(json.dumps(row) + "\n")

    with (out_dir / f"{prefix}_per_class.csv").open("w", newline="") as f:
        w = csv.writer(f, quoting=csv.QUOTE_ALL)
        w.writerow(["class_id", "class_name", "semantic_kind", "targets", "instances", "hits", "recall"])
        for cid in sorted(per_class):
            pc = per_class[cid]
            w.writerow(
                [
                    cid,
                    taxonomy[cid]["name"],
                    taxonomy[cid]["kind"],
                    ";".join(map(str, taxonomy[cid]["targets"])),
                    pc["instances"],
                    pc["hits"],
                    round(pc["hits"] / pc["instances"], 4) if pc["instances"] else "",
                ]
            )
    print(json.dumps({k: v for k, v in scores.items() if k != "unjustified_examples"}, indent=1))


if __name__ == "__main__":
    main()
