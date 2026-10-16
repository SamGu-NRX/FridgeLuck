#!/usr/bin/env python3
"""Measure catalog reach before/after the pantry-2026-10 batch.

Replays the repository's own reach evaluation (evaluation/catalog-reach/
reach_report_v2.py, unchanged) over the shipped iOS bundle and over the
shipped bundle plus this packet's 30 records appended as bundle recipes.
The delta is the batch's measured contribution: exact-cookable ("cookable
now") recipes per written household pantry and the median across the ten
pantries.

Recipe-to-bundle mapping: the reach machinery speaks bundle ingredient keys
(recipes-v2.json "ingredients"), resolving each key to app ingredient ids via
legacy/USDA rows; pantry items resolve by exact written name, snake_case, and
plural folds. RS ingredient names are therefore mapped to bundle keys with the
explicit NAME_TO_KEY table below — every key is asserted to exist in the
shipped bundle vocabulary, and a miss fails the run loudly rather than
silently dropping a line. All lines are required; "to taste" seasonings
(quantity kind "u") are marked assumed_staple, mirroring the bundle's flag,
because a pantry-independent seasoning never blocks a cook.

Diet claims for the appended records are derived from line composition with
the RS classification's ingredient names: flesh lines (chicken breast, pork
chop, canned tuna, salmon) block vegetarian; animal lines (flesh plus eggs,
milk, butter, cheddar, yogurt) block vegan; dairy lines block dairy_free;
wheat lines (pasta, bread) block gluten_free. This mirrors the build
compiler's class-based claim derivation at the RS layer's name level.

Usage: python3 run_reach.py   (writes evidence/reach-after.json, prints a table)
"""
from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
REPO = PKG.parents[2]
sys.path.insert(0, str(REPO / "evaluation" / "catalog-reach"))

import reach_report_v2 as rr  # noqa: E402  (repo evaluation module, unchanged)

SHIPPED_BUNDLE = REPO / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"
PANTRIES = REPO / "evaluation" / "catalog-reach" / "pantries-v2.json"
CORPUS = PKG / "originals.jsonl"
OUT = PKG / "evidence" / "reach-after.json"

# RS ingredient name -> shipped bundle ingredient key. Singular bundle
# spellings ('egg', 'potato', 'pork_chop'); 'rolled oats' maps to the bundle's
# generic 'oats'. The runner asserts every key exists in the bundle vocabulary.
NAME_TO_KEY = {
    "rice": "rice",
    "eggs": "egg",
    "soy sauce": "soy_sauce",
    "olive oil": "olive_oil",
    "garlic": "garlic",
    "salt": "salt",
    "black pepper": "black_pepper",
    "pasta": "pasta",
    "chicken breast": "chicken_breast",
    "milk": "milk",
    "butter": "butter",
    "cheddar": "cheddar",
    "onion": "onion",
    "corn": "corn",
    "potatoes": "potato",
    "spinach": "spinach",
    "chickpeas": "chickpeas",
    "cumin": "cumin",
    "quinoa": "quinoa",
    "peanut butter": "peanut_butter",
    "tofu": "tofu",
    "black beans": "black_beans",
    "broccoli": "broccoli",
    "canned tuna": "canned_tuna",
    "bread": "bread",
    "yogurt": "yogurt",
    "cilantro": "cilantro",
    "ginger": "ginger",
    "turmeric": "turmeric",
    "pork chop": "pork_chop",
    "apple": "apple",
    "lemon": "lemon",
    "salmon": "salmon",
    "rolled oats": "oats",
    "sugar": "sugar",
    "cinnamon": "cinnamon",
    "zucchini": "zucchini",
    "avocado": "avocado",
    "cauliflower": "cauliflower",
}

# Composition classes for claim derivation (see module docstring).
FLESH = {"chicken breast", "pork chop", "canned tuna", "salmon"}
ANIMAL = FLESH | {"eggs", "milk", "butter", "cheddar", "yogurt"}
DAIRY = {"milk", "butter", "cheddar", "yogurt"}
WHEAT = {"pasta", "bread"}


def pseudo_recipe(record: dict, vocabulary_keys: set[str]) -> dict:
    """Bundle-recipe row for one RS record, keyed into the bundle vocabulary."""
    lines: list[dict] = []
    names: set[str] = set()
    for line in record["ingredients"]:
        name = line["name"].lower()
        names.add(name)
        key = NAME_TO_KEY.get(name)
        if key is None:
            raise SystemExit(f"{record['id']}: ingredient {name!r} has no "
                             f"NAME_TO_KEY mapping; add it explicitly")
        if key not in vocabulary_keys:
            raise SystemExit(f"{record['id']}: mapped key {key!r} for "
                             f"{name!r} is not in the shipped bundle vocabulary")
        qty = line["qty"]
        if qty["kind"] == "household":
            quantity = {"kind": "household", "amount": qty["value"],
                        "unit": qty["unit"], "grams": qty.get("grams")}
        elif qty["kind"] == "grams":
            quantity = {"kind": "grams", "grams": qty.get("grams")}
        else:  # unknown / "to taste": pantry-independent seasoning
            quantity = {"kind": "unknown", "note": qty.get("note")}
        lines.append({
            "key": key,
            "quantity": quantity,
            "required": True,
            "assumed_staple": qty["kind"] == "unknown",
            "note": None,
        })
    return {
        "catalog_id": record["id"],
        "title": record["title"],
        "ingredients": lines,
        "claims": {
            "vegetarian": not names & FLESH,
            "vegan": not names & ANIMAL,
            "dairy_free": not names & DAIRY,
            "gluten_free": not names & WHEAT,
        },
    }


def main() -> int:
    shipped = json.loads(SHIPPED_BUNDLE.read_text())
    spec = json.loads(PANTRIES.read_text())
    records = [json.loads(l) for l in CORPUS.read_text().splitlines() if l.strip()]
    vocabulary_keys = {row["key"] for row in shipped["ingredients"]}

    before = rr.analyze_bundle(shipped, REPO, spec)
    augmented = dict(shipped)
    augmented["recipes"] = shipped["recipes"] + [
        pseudo_recipe(r, vocabulary_keys) for r in records]
    after = rr.analyze_bundle(augmented, REPO, spec)

    per_pantry: dict[str, dict] = {}
    for name in before["per_pantry"]:
        b = before["per_pantry"][name]["cookable_now_count"]
        a = after["per_pantry"][name]["cookable_now_count"]
        added = [cid for cid in after["per_pantry"][name]["per_diet_cookable"]["omnivore"]
                 if cid.startswith("fl-pantry-")]
        per_pantry[name] = {
            "exact_before": b,
            "exact_after": a,
            "added": added,
            "unresolved_items": after["per_pantry"][name]["unresolved_items"],
        }

    medians = {
        "exact_before": statistics.median(p["exact_before"] for p in per_pantry.values()),
        "exact_after": statistics.median(p["exact_after"] for p in per_pantry.values()),
    }
    summary = {
        "bundle_version": shipped.get("bundle_version"),
        "records_appended": len(records),
        "method": ("reach_report_v2.analyze_bundle replayed over the shipped "
                   "bundle, then over the shipped bundle plus the 30 "
                   "pantry-2026-10 records; RS ingredient names mapped to "
                   "shipped bundle keys via the explicit NAME_TO_KEY table"),
        "medians": medians,
        "per_pantry": per_pantry,
    }
    OUT.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")

    width = max(len(n) for n in per_pantry)
    print(f"{'pantry':{width}s}  before  after  added")
    for name, p in per_pantry.items():
        print(f"{name:{width}s}  {p['exact_before']:6d}  {p['exact_after']:5d}  "
              f"{', '.join(p['added']) or '-'}")
    print(f"median exact cookable: {medians['exact_before']} -> "
          f"{medians['exact_after']}")
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
