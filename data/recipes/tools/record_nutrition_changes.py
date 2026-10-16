#!/usr/bin/env python3
"""Record >40% per-serving kcal moves between two published recipe bundles.

When a vocabulary revision resolves ingredient keys that previously shipped
without per-100g nutrition, recipes can move materially. Every move of more
than 40 percent must be recorded in data/recipe-bundle/nutrition-changes-2026-10.json
naming the vocabulary keys that were resolved and are used by that recipe.
validate_bundle.py --previous <old bundle> --changes <this file> enforces it.

The cause is computed honestly: a recipe's entry lists exactly the keys in its
lines that gained a per-100g row between the previous and current vocabulary.
If a swing cannot be traced to any resolved key in the recipe, the tool fails
closed instead of writing an unexplained exemption.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT_DEFAULT = REPO / "data/recipe-bundle/nutrition-changes-2026-10.json"
VOCAB = REPO / "data/ingredients/vocabulary.json"
DRIFT_THRESHOLD = 0.40


def kcal_swing(old: float, new: float) -> float:
    if old == 0:
        return 0.0 if new == 0 else float("inf")
    return abs(new - old) / old


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--new", default=str(REPO / "data/recipes/build/recipes-v2.json"),
                    help="newly compiled bundle")
    ap.add_argument("--previous", required=True, help="previously published bundle")
    ap.add_argument("--previous-vocab", required=True,
                    help="vocabulary.json as committed with the previous bundle")
    ap.add_argument("--out", default=str(OUT_DEFAULT))
    ap.add_argument("--previous-note", required=True,
                    help="provenance of the previous bundle, e.g. the commit sha it ships in")
    args = ap.parse_args()

    new = json.load(open(args.new))
    prev = json.load(open(args.previous))
    cur_vocab = {e["key"]: e for e in json.load(VOCAB.open())["entries"]}
    prev_vocab = {e["key"]: e for e in json.load(open(args.previous_vocab))["entries"]}

    # Keys that gained a per-100g row between the two vocabulary revisions.
    resolved = {
        k: cur_vocab[k] for k in cur_vocab
        if cur_vocab[k].get("per_100g") is not None
        and prev_vocab.get(k, {}).get("per_100g") is None
    }
    print(f"vocabulary keys resolved between revisions: {len(resolved)}")

    prev_n = {r["catalog_id"]: r["nutrition_per_serving"] for r in prev["recipes"]}
    entries = []
    unexplained = []
    for recipe in new["recipes"]:
        rid = recipe["catalog_id"]
        old_n = prev_n.get(rid)
        if old_n is None:
            continue
        n = recipe["nutrition_per_serving"]
        swing = kcal_swing(old_n["kcal"], n["kcal"])
        if swing <= DRIFT_THRESHOLD:
            continue
        line_keys = {line["key"] for line in recipe["ingredients"]}
        cause = sorted(k for k in line_keys if k in resolved)
        if not cause:
            unexplained.append(rid)
            continue
        detail = ", ".join(f"{k} (fdc {resolved[k]['fdc_id']})" for k in cause)
        entries.append({
            "catalog_id": rid,
            "old_kcal": old_n["kcal"],
            "new_kcal": n["kcal"],
            "vocabulary_change": f"keys in this recipe resolved to per-100g rows "
                                 f"in this revision: {detail}",
        })
    if unexplained:
        raise SystemExit(
            "kcal swings with no resolved vocabulary key in the recipe lines: "
            f"{sorted(unexplained)} — investigate before exempting")

    entries.sort(key=lambda e: e["catalog_id"])
    doc = {
        "note": "Recipes whose per-serving kcal moved more than 40 percent against the "
                "previously published bundle, with the vocabulary resolution that caused "
                "each move. Recorded by data/recipes/tools/record_nutrition_changes.py; "
                "enforced by validate_bundle.py --previous --changes.",
        "policy": "A >40% kcal move between published bundles must be exempted here with "
                  "the vocabulary change that caused it; exemption entries must reproduce "
                  "both kcal values.",
        "previous_bundle": args.previous_note,
        "threshold": DRIFT_THRESHOLD,
        "entries": entries,
    }
    Path(args.out).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {args.out}: {len(entries)} exempted kcal moves "
          f"(of {len(new['recipes'])} recipes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
