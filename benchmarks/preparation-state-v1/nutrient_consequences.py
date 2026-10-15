#!/usr/bin/env python3
"""Nutrient consequences of wrong-state and ungrounded-state predictions.

The bundled catalog stores nutrition per 100 g per record, so a wrong-state
answer does not just misname the food — it silently swaps the nutrient basis
(e.g. cooked->raw under-reports energy for foods that gain calories from
cooking/fat). This script quantifies that cost:

  - text arms (results/text_arms/predictions.jsonl): for every wrong_state
    prediction, per-100 g deltas (predicted - target) for calories, protein,
    carbs, fat, fiber, sugar, sodium, aggregated by confusion pair.
  - image arm (results/image_inference/): FoodSeg103 has no state labels, so
    there is no "wrong" state on image; instead we report the nutrient spread
    WITHIN each multi-alternative group that the pipeline bound a stateful
    record for — the nutrition that hangs on an ungrounded state choice.

Run: python3 nutrient_consequences.py   (writes results/nutrient_consequences.json)
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH_ROOT))

from run import catalog_rows  # noqa: E402

NUTRIENTS = ["calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium"]
KEY_NUTRIENT = "calories"


def states_for_record(prep: dict) -> dict[int, list[str]]:
    out = {}
    for g in prep["groups"]:
        for m in g["members"]:
            out[m["catalog_id"]] = m["states"]
    return out


def confusion_key(target_state: str, pred_states: list[str]) -> str:
    return f"{target_state}->{','.join(pred_states) if pred_states else 'stateless'}"


def text_arm_consequences(records: list[dict], rows: dict[int, dict], states_by_id: dict[int, list[str]]) -> dict:
    pairs: dict[str, list[dict]] = {}
    for r in records:
        if r["outcome"] != "wrong_state" or r["predicted_record_id"] is None:
            continue
        pred = rows.get(r["predicted_record_id"])
        target = rows.get(r["target_record_id"])
        if not pred or not target:
            continue
        key = confusion_key(r["target_state"], states_by_id.get(r["predicted_record_id"], []))
        deltas = {}
        for n in NUTRIENTS:
            pv, tv = pred["per100g"][n], target["per100g"][n]
            deltas[n] = {
                "delta_per_100g": round(pv - tv, 4),
                "pct": round((pv - tv) / tv * 100, 4) if tv else None,
            }
        pairs.setdefault(key, []).append(deltas)

    summary: dict[str, dict] = {}
    for key, items in sorted(pairs.items(), key=lambda kv: -len(kv[1])):
        kcal_pcts = [d[KEY_NUTRIENT]["pct"] for d in items if d[KEY_NUTRIENT]["pct"] is not None]
        per_nutrient = {}
        for n in NUTRIENTS:
            pcts = [d[n]["pct"] for d in items if d[n]["pct"] is not None]
            per_nutrient[n] = {
                "mean_pct": round(statistics.fmean(pcts), 2) if pcts else None,
                "median_pct": round(statistics.median(pcts), 2) if pcts else None,
            }
        summary[key] = {
            "n": len(items),
            "kcal": {
                "mean_pct": round(statistics.fmean(kcal_pcts), 2) if kcal_pcts else None,
                "median_pct": round(statistics.median(kcal_pcts), 2) if kcal_pcts else None,
                "max_abs_pct": round(max((abs(p) for p in kcal_pcts), default=0.0), 2),
                "beyond_20pct": sum(1 for p in kcal_pcts if abs(p) > 20),
            },
            "per_nutrient_mean_pct": {n: per_nutrient[n]["mean_pct"] for n in NUTRIENTS},
        }
    return summary


def image_arm_consequences(prep: dict, rows: dict[int, dict], image_predictions: Path) -> dict:
    group_members: dict[str, list[int]] = {}
    for g in prep["groups"]:
        group_members[g["group_id"]] = [m["catalog_id"] for m in g["members"]]

    spreads: list[float] = []
    bindings = 0
    groups_seen: set[str] = set()
    with image_predictions.open() as f:
        for line in f:
            rec = json.loads(line)
            for det in rec["detections"]:
                gid = det["group_id"]
                if gid in group_members and len(group_members[gid]) >= 2 and det["stateful"]:
                    bindings += 1
                    groups_seen.add(gid)
                    kcal_values = [rows[i]["per100g"][KEY_NUTRIENT] for i in group_members[gid] if i in rows]
                    if len(kcal_values) >= 2 and min(kcal_values) > 0:
                        spread = (max(kcal_values) - min(kcal_values)) / (sum(kcal_values) / len(kcal_values)) * 100
                        spreads.append(round(spread, 2))

    return {
        "ungrounded_stateful_bindings_on_multi_groups": bindings,
        "distinct_groups_bound": len(groups_seen),
        "kcal_spread_within_bound_groups": {
            "mean_pct_of_mean": round(statistics.fmean(spreads), 2) if spreads else None,
            "median_pct_of_mean": round(statistics.median(spreads), 2) if spreads else None,
            "max_pct_of_mean": round(max(spreads), 2) if spreads else None,
            "bindings_beyond_20pct": sum(1 for s in spreads if s > 20),
            "note": (
                "Spread is (max-min) kcal per 100 g across the group's state records, as % "
                "of the group mean kcal. Each binding picks one member with no image state "
                "evidence, so this spread is the nutrition exposed to an ungrounded choice."
            ),
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench-root", default=str(BENCH_ROOT))
    args = ap.parse_args()
    bench = Path(args.bench_root)
    results = bench / "results"

    prep = json.loads((bench / "manifest.json").read_text())
    rows = catalog_rows()
    states_by_id = states_for_record(prep)

    out: dict = {"benchmark": prep["benchmark"], "nutrients": NUTRIENTS, "key_nutrient": KEY_NUTRIENT}

    text_preds = results / "text_arms" / "predictions.jsonl"
    if text_preds.exists():
        records = [json.loads(line) for line in text_preds.read_text().splitlines()]
        by_arm: dict[str, list[dict]] = {}
        for r in records:
            by_arm.setdefault(r["arm"], []).append(r)
        out["text_arms"] = {
            arm: text_arm_consequences(recs, rows, states_by_id) for arm, recs in sorted(by_arm.items())
        }
        out["text_arms_wrong_state_pairs_with_target_record"] = sum(
            section["n"] for arm in out["text_arms"].values() for section in arm.values()
        )

    image_preds = results / "image_inference" / "image_predictions.jsonl"
    if image_preds.exists():
        out["image_inference"] = image_arm_consequences(prep, rows, image_preds)

    dest = results / "nutrient_consequences.json"
    dest.write_text(json.dumps(out, indent=1, sort_keys=True) + "\n")
    print(json.dumps(out, indent=1)[:4000])
    print(f"wrote {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
