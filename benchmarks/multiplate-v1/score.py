#!/usr/bin/env python3
"""Score multiplate-v1 run outputs against the frozen manifest.

Reads results/predictions_{arm}.jsonl from run.py and emits results/summary.json
plus a printed markdown table.

Metrics (IoU 0.5, optimal same-category assignment from matching.py):
  matched / precision / recall     overall and per role (multi, control)
  missed_small_frac                fraction of small GT regions (< 4% image area) unmatched
  duplicates                       extra detections on already-covered GT regions (FP subset)
  confusion                        cross-class overlaps (pred label -> GT label, IoU >= 0.5)
  region_count_error               mean |n_pred - n_gt| per image (mean absolute, mean signed)
  (oracle-crops only) crop_accuracy: classifier label == GT label on GT boxes

NOTE: GT boxes count food categories, not servings or plates; region-count error
measures agreement with category boxes only.

Usage (from repo root):
  python3 benchmarks/multiplate-v1/score.py --manifest benchmarks/multiplate-v1/manifest.json \
      --results benchmarks/multiplate-v1/results
"""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

from matching import iou, match_detections

SMALL_REGION_FRAC = 0.04


def gt_boxes_norm(im: dict) -> list[dict]:
    """Manifest image entry -> normalized GT box list for matching."""
    return [
        {"label": b["label_name"], "box": [b["xmin"], b["ymin"], b["xmax"], b["ymax"]]}
        for b in im["boxes"]
    ]


def evaluate_arm(manifest: dict, preds: dict[str, dict], is_oracle: bool = False) -> dict:
    """preds: image_id -> {detections: [...]} (already per-image lists)."""
    multi = Counter()
    control = Counter()
    total = Counter()
    missed_small = [0, 0]  # [missed, total_small]
    duplicates = 0
    confusion: Counter = Counter()
    count_errors_abs = []
    count_errors_signed = []
    oracle_correct = [0, 0, 0]  # [correct, classified, gt_total]

    for im in manifest["images"]:
        gts = gt_boxes_norm(im)
        det_rows = preds.get(im["image_id"], {}).get("detections", [])
        if is_oracle:
            # oracle arm: one detection per GT box, classification accuracy only
            oracle_correct[2] += len(im["boxes"])
            for d in det_rows:
                oracle_correct[1] += 1
                if d.get("label") == d.get("gt_label"):
                    oracle_correct[0] += 1
            continue

        dets = [{"label": d["label"], "box": d["box"]} for d in det_rows]
        res = match_detections(dets, gts, iou_threshold=0.5, optimal=True)
        matched_i = {i for i, _, _ in res["matches"]}
        n_gt = len(gts)
        n_det = len(dets)
        tp = res["true_positives"]
        bucket = control if im["role"] == "control" else multi
        bucket["gt"] += n_gt
        bucket["det"] += n_det
        bucket["tp"] += tp
        total["gt"] += n_gt
        total["det"] += n_det
        total["tp"] += tp

        # missed small regions
        matched_j = set()
        for i, j, _ in res["matches"]:
            matched_j.add(j)
        for j, g in enumerate(gts):
            area = (g["box"][2] - g["box"][0]) * (g["box"][3] - g["box"][1])
            if area < SMALL_REGION_FRAC:
                missed_small[1] += 1
                if j not in matched_j:
                    missed_small[0] += 1

        # duplicates: unmatched dets that overlap an already-matched GT >= 0.5
        for i, d in enumerate(dets):
            if i in matched_i:
                continue
            for j in matched_j:
                if iou(d["box"], gts[j]["box"]) >= 0.5:
                    duplicates += 1
                    break

        # category confusion: unmatched dets overlapping any GT box (cross-class)
        for i, d in enumerate(dets):
            if i in matched_i:
                continue
            best_j, best_iou = None, 0.0
            for j, g in enumerate(gts):
                v = iou(d["box"], g["box"])
                if v > best_iou:
                    best_iou, best_j = v, j
            if best_j is not None and best_iou >= 0.5 and d["label"] != gts[best_j]["label"]:
                confusion[(d["label"], gts[best_j]["label"])] += 1

        count_errors_abs.append(abs(n_det - n_gt))
        count_errors_signed.append(n_det - n_gt)

    def prf(c: Counter) -> dict:
        tp, det, gt = c["tp"], c["det"], c["gt"]
        return {
            "gt_boxes": gt,
            "detections": det,
            "true_positives": tp,
            "precision": round(tp / det, 4) if det else None,
            "recall": round(tp / gt, 4) if gt else None,
        }

    out = {
        "overall": prf(total),
        "multi_role": prf(multi),
        "control_role": prf(control),
        "missed_small_regions": {
            "small_gt_total": missed_small[1],
            "missed": missed_small[0],
            "missed_frac": round(missed_small[0] / missed_small[1], 4) if missed_small[1] else None,
        },
        "duplicates_on_matched_gt": duplicates,
        "category_confusion_top": {
            f"{a} -> {b}": n for (a, b), n in confusion.most_common(10)
        },
        "region_count_error": {
            "mean_abs": round(sum(count_errors_abs) / len(count_errors_abs), 3)
            if count_errors_abs
            else None,
            "mean_signed": round(sum(count_errors_signed) / len(count_errors_signed), 3)
            if count_errors_signed
            else None,
        },
    }
    if oracle_correct[1] or oracle_correct[2]:
        out["oracle_crop_accuracy"] = round(oracle_correct[0] / oracle_correct[1], 4)
        out["oracle_crops_classified"] = oracle_correct[1]
        out["oracle_gt_total"] = oracle_correct[2]
        out["oracle_coverage"] = round(oracle_correct[1] / oracle_correct[2], 4)
    return out


def load_predictions(results_dir: Path, arm: str) -> dict[str, dict]:
    path = results_dir / f"predictions_{arm}.jsonl"
    preds: dict[str, dict] = {}
    if not path.exists():
        return preds
    with open(path) as f:
        for line in f:
            row = json.loads(line)
            preds[row["image_id"]] = row
    return preds


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--results", type=Path, required=True)
    args = ap.parse_args()

    manifest = json.loads(args.manifest.read_text())
    arms = [
        p.stem.removeprefix("predictions_")
        for p in sorted(args.results.glob("predictions_*.jsonl"))
    ]
    summary: dict = {"arms": {}}
    for arm in arms:
        preds = load_predictions(args.results, arm)
        summary["arms"][arm] = evaluate_arm(manifest, preds, is_oracle=(arm == "oracle-crops"))
    (args.results / "summary.json").write_text(json.dumps(summary, indent=1))

    print("| arm | precision | recall | det | TP | GT | missed small | dup | count err (abs) |")
    print("|---|---|---|---|---|---|---|---|---|")
    for arm, m in summary["arms"].items():
        o = m["overall"]
        ms = m["missed_small_regions"]
        if arm == "oracle-crops":
            print(
                f"| {arm} (upper bound) | - | - | - | - | - | - | - | crop_acc={m.get('oracle_crop_accuracy')} |"
            )
        else:
            print(
                f"| {arm} | {o['precision']} | {o['recall']} | {o['detections']} | {o['true_positives']} | {o['gt_boxes']} "
                f"| {ms['missed_frac']} | {m['duplicates_on_matched_gt']} | {m['region_count_error']['mean_abs']} |"
            )
    print(f"\nwrote {args.results / 'summary.json'}")


if __name__ == "__main__":
    main()
