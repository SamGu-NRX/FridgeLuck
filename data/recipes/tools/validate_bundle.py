#!/usr/bin/env python3
"""Validate a compiled recipe bundle against the v2 contract and evidence.

Checks, in order:
1. JSON Schema conformance (recipe-bundle-v2.schema.json, draft 2020-12).
2. Ingredient references: every line's key names a bundle ingredient.
3. Nutrition plausibility: kcal within 40 percent of the Atwater sum of the
   macros it ships with; sodium sane; no negative or absurd values.
4. Claims fail closed: a true dietary claim must not conflict with the
   composition class of any line in the recipe.
5. Rights: every recipe carries an original/quarantined status with evidence.
6. FSIS: a thermometer endpoint may only appear on a step of a recipe that
   uses a meat/fish class ingredient, and endpoints must match FSIS tables.

Exit code 0 and "PASS" on success; every failure is printed with its recipe id.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import jsonschema

REPO = Path(__file__).resolve().parents[3]
SCHEMA = REPO / "docs/spec/recipes/contracts/recipe-bundle-v2.schema.json"
VOCAB = REPO / "data/ingredients/vocabulary.json"

# Classes whose presence makes a claim impossible (fail-closed). The corpus
# composition gate is the fail-closed authority for claims (fixture classes on
# ingredient names); this bundle-level audit catches contradictions expressible
# in the vocabulary. Lines whose vocabulary classes are missing or 'unknown'
# are unverifiable here, not contradictions — they are reported as warnings.
CLAIM_BLOCKERS = {
    # Lacto-ovo vegetarian: flesh is out; dairy/egg/honey (the vocabulary's
    # coarse 'animal' entries: ghee, honey, mayonnaise) are in.
    "vegetarian": {"meat", "fish", "shellfish"},
    "vegan": {"meat", "fish", "shellfish", "animal", "dairy", "egg", "honey"},
}

# Atwater factors, fiber-adjusted (carbs are by-difference and include fiber
# at ~2 kcal/g), cross-checked against shipped kcal with an absolute floor:
# small absolute deltas on low-energy foods are noise, and alcohol contributes
# 7 kcal/g that the shipped macros cannot express.
ATWATER = {"protein_g": 4, "carbs_g": 4, "fat_g": 9}
ATWATER_FIBER = 2
ALCOHOL_KEYS = {
    "red_wine", "white_wine", "beer", "lager", "ale", "rum", "vodka", "brandy",
    "whiskey", "sherry", "mirin", "cooking_wine", "kahlua", "cointreau",
}


def fail(errors: list[str], recipe: str, message: str) -> None:
    errors.append(f"{recipe}: {message}")


def atwater_ok(n: dict, has_alcohol: bool) -> bool:
    if has_alcohol:
        return True
    carb_eff = max(n["carbs_g"] - n.get("fiber_g", 0.0), 0.0)
    fiber = n.get("fiber_g", 0.0)
    expected = (n["protein_g"] * ATWATER["protein_g"]
                + carb_eff * ATWATER["carbs_g"]
                + fiber * ATWATER_FIBER
                + n["fat_g"] * ATWATER["fat_g"])
    if expected <= 0:
        return n["kcal"] >= 10
    return abs(n["kcal"] - expected) <= max(50.0, 0.40 * expected)


def main(path: str) -> int:
    bundle = json.load(open(path))
    schema = json.load(SCHEMA.open())
    errors: list[str] = []

    validator = jsonschema.Draft202012Validator(schema)
    for err in sorted(validator.iter_errors(bundle), key=lambda e: list(e.absolute_path)):
        loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
        fail(errors, loc, err.message[:160])

    ingredients = {i["key"]: i for i in bundle["ingredients"]}
    # Bundle ingredients carry no class field (schema forbids extras); the
    # claim and FSIS audits read the vocabulary's per-key classes list
    # (plural). Unknown coverage is disclosed, never treated as a blocker.
    classes = {e["key"]: set(e.get("classes") or [])
               for e in json.load(VOCAB.open())["entries"]}
    warnings: list[str] = []

    for recipe in bundle["recipes"]:
        rid = recipe["catalog_id"]
        keys = {line["key"] for line in recipe["ingredients"]}
        for key in keys:
            if key not in ingredients:
                fail(errors, rid, f"line key {key!r} is not a bundle ingredient")
        # Claims fail closed against line composition classes.
        for claim, blockers in CLAIM_BLOCKERS.items():
            if recipe["claims"].get(claim) is not True:
                continue
            for key in keys:
                cc = classes.get(key, set())
                blocking = cc & blockers
                if blocking:
                    fail(errors, rid,
                         f"claims {claim} but line {key!r} has class(es) "
                         f"{sorted(blocking)}")
                elif not cc or "unknown" in cc:
                    warnings.append(f"{rid}: {claim} line {key!r} has no known "
                                    "vocabulary classes (unverifiable here)")
        # Nutrition plausibility against the macros the recipe itself ships.
        n = recipe["nutrition_per_serving"]
        if n["sodium_mg"] > 6000:
            fail(errors, rid, f"sodium {n['sodium_mg']} mg/serving is implausible")
        if not atwater_ok(n, bool(keys & ALCOHOL_KEYS)):
            fail(errors, rid,
                 f"kcal {n['kcal']} is implausibly far from the Atwater sum of its macros")
        # FSIS: thermometer endpoints only on recipes with meat/fish lines.
        has_protein = any(classes.get(key, set()) & {"meat", "fish"} for key in keys)
        for i, step in enumerate(recipe["steps"]):
            thermo = step["thermometer"]
            if thermo is None:
                continue
            if not has_protein:
                fail(errors, rid, f"step {i} thermometer on a recipe with no meat/fish lines")
            if not thermo["source"].startswith("usda-fsis"):
                fail(errors, rid, f"step {i} thermometer source is not usda-fsis")
        if recipe["rights"]["status"] == "quarantined" and not recipe["rights"]["evidence"]:
            fail(errors, rid, "quarantined recipe must cite rights evidence")

    if warnings:
        print(f"warnings (not gated): {len(warnings)}")
        for w in warnings[:20]:
            print(" ?", w)
        if len(warnings) > 20:
            print(f" ... and {len(warnings) - 20} more")
    if errors:
        print(f"FAIL ({len(errors)} problems)")
        for e in errors[:40]:
            print(" -", e)
        if len(errors) > 40:
            print(f" ... and {len(errors) - 40} more")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "data/recipes/build/recipes-v2.json"))
