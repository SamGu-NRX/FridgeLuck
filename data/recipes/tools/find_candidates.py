#!/usr/bin/env python3
"""List FDC candidate rows for the keys that lack per-100g data.

Exact-word search over FNDDS survey + SR Legacy (+ optional Foundation Foods)
descriptions: every key word must appear as an exact word form (singular or
plural); prints candidates with nutrient availability for hand review.
No scoring, no ranking, no fuzzy: this is an evidence dump for a human decision.
"""
from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

FDC_DIRS = {
    "fndds": Path("/tmp/fdc/FoodData_Central_survey_food_csv_2024-10-31"),
    "sr": Path("/tmp/fdc/FoodData_Central_sr_legacy_food_csv_2018-04"),
}
FF_DIR = Path("/tmp/fdc/FoodData_Central_foundation_food_csv_2024-10-31")

NUTRIENT_IDS = {"kcal": {1008, 208}, "protein_g": {1003, 203},
                "carbs_g": {1005, 205}, "fat_g": {1004, 204},
                "fiber_g": {1079, 291}, "sugar_g": {2000, 1063, 269},
                "sodium_mg": {1093, 307}}

def load():
    foods = {}
    nutrients: dict[int, set[str]] = {}
    for d in [FF_DIR] if FF_DIR.exists() else []:
        pass
    for tag, d in FDC_DIRS.items():
        with (d / "food.csv").open() as f:
            for row in csv.DictReader(f):
                foods[int(row["fdc_id"])] = (row["description"], tag)
        with (d / "food_nutrient.csv").open() as f:
            for row in csv.DictReader(f):
                fid = int(row["fdc_id"])
                nid = int(row["nutrient_id"])
                for field, ids in NUTRIENT_IDS.items():
                    if nid in ids:
                        nutrients.setdefault(fid, set()).add(field)
    if FF_DIR.exists():
        with (FF_DIR / "food.csv").open() as f:
            for row in csv.DictReader(f):
                foods[int(row["fdc_id"])] = (row["description"], "ff")
        with (FF_DIR / "food_nutrient.csv").open() as f:
            for row in csv.DictReader(f):
                fid = int(row["fdc_id"])
                nid = int(row["nutrient_id"])
                for field, ids in NUTRIENT_IDS.items():
                    if nid in ids:
                        nutrients.setdefault(fid, set()).add(field)
    return foods, nutrients

def word_forms(w: str) -> set[str]:
    f = {w, w + "s", w + "es"}
    if w.endswith("y"):
        f.add(w[:-1] + "ies")
    # rough singulars
    if w.endswith("es"):
        f.add(w[:-2])
    if w.endswith("s"):
        f.add(w[:-1])
    return f

def main() -> None:
    foods, nutrients = load()
    vocab = json.load(open(sys.argv[1]))["entries"]
    targets = [e["key"] for e in vocab if e["per_100g"] is None]
    if len(sys.argv) > 2:
        targets = sys.argv[2:]
    for key in targets:
        words = [w for w in key.split("_") if w]
        forms = {w: word_forms(w) for w in words}
        print(f"### {key}")
        hits = []
        for fid, (desc, tag) in foods.items():
            dl = desc.lower()
            tokens = set(re.findall(r"[a-z]+", dl))
            if all(any(t in forms[w] for t in tokens) for w in words):
                hits.append((fid, desc, tag, len(nutrients.get(fid, ()))))
        for fid, desc, tag, nfields in sorted(hits, key=lambda h: (-h[3], h[1]))[:14]:
            print(f"  {fid} [{tag}] ({nfields}/7 nutrients) {desc}")
        if not hits:
            print("  (no exact-word candidates)")
    return

if __name__ == "__main__":
    main()
