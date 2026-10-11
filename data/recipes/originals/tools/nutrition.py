#!/usr/bin/env python3
"""Per-serving nutrition for the FridgeLuck originals corpus.

Computes nutrition ONLY from in-repo committed values, scaled by each
ingredient line's evidenced grams:

1. the bundled USDA catalog sqlite (`usda_ingredient_catalog.sqlite`, rows
   carry matched FDC IDs), referenced by {"fdc_id": int}; or
2. the bundled app core-ingredient table (`apps/ios/Resources/data.json`,
   50 items with per-100g macros shipped at the pinned alpha), referenced by
   {"bundled_id": "3"} (the data.json ingredient id).

Ingredient-name -> source mapping lives in per-part shards
(`<part>/tables/nutrition-map.json`) so two writer threads never edit one
file. An ingredient with no mapping contributes nothing and is reported as
unmapped; the share of gram weight it covers is written as `coverage`.

If an UNMAPPED ingredient matches a salty pattern (fish sauce, soy, stock,
salt, cured meats, cheese, pickles, ...) the written block carries
`sodium_basis: "incomplete-salty-unmapped"`: the displayed sodium
under-counts and the app must not present it as a trustworthy number.
This matches the overhaul SPEC: unsupported values are left unsourced
rather than guessed - but the gap is stated.

Usage:
    python3 tools/nutrition.py --write --all
    python3 tools/nutrition.py --write --part east-southeast-asian
    python3 tools/nutrition.py --check --all
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import originals_common as oc  # noqa: E402

NUTRIENT_COLS = ("calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium")

# salty-pattern knowledge lives in originals_common (shared with validate.py)
SALTY_PATTERNS = oc.SALTY_PATTERNS


def catalog_rows() -> dict[int, dict[str, float]]:
    db = sqlite3.connect(f"file:{oc.bundled_sqlite_path()}?mode=ro", uri=True)
    rows: dict[int, dict[str, float]] = {}
    for row in db.execute(
        f"SELECT fdc_id, {', '.join(NUTRIENT_COLS)} FROM ingredient_catalog"
    ):
        vals = {col: float(row[i + 1]) for i, col in enumerate(NUTRIENT_COLS)}
        # the bundled catalog stores sodium as g/100g (verified: 'White Rice
        # (Cooked)' 0.007, 'Soy Sauce (Tamari)' 5.586); the rest are per-100g
        # in their natural units already.
        vals["sodium"] *= 1000.0
        rows[int(row[0])] = vals
    db.close()
    return rows


def bundled_core_rows() -> dict[str, dict[str, float]]:
    """The app's own 50-ingredient table from data.json (verified on alpha
    2e77938): [name, kcal, protein, carbs, fat, fiber, sugar,
    sodium_g_per_100g, unit, storage]."""
    data = json.loads(oc.bundled_data_json_path().read_text())
    rows: dict[str, dict[str, float]] = {}
    for iid, v in data["ingredients"].items():
        rows[str(iid)] = {
            "calories": float(v[1]), "protein": float(v[2]), "carbs": float(v[3]),
            "fat": float(v[4]), "fiber": float(v[5]), "sugar": float(v[6]),
            "sodium": float(v[7]) * 1000.0,  # stored g/100g -> mg/100g
        }
    return rows


def load_maps(part: str | None = None) -> tuple[dict[str, dict], list[str]]:
    """ingredient name (lowercase) -> {'fdc_id': int} or {'bundled_id': str}."""
    m: dict[str, dict] = {}
    errors: list[str] = []
    for shard_path in oc.table_shards("nutrition-map.json", part):
        data = json.loads(shard_path.read_text())
        for name, entry in data.get("maps", {}).items():
            key = name.strip().lower()
            if key in m and m[key] != entry:
                errors.append(f"{shard_path}: conflicting source for {key!r}")
            m[key] = entry
    return m, errors


def compute(r: dict, rows: dict[int, dict[str, float]], core_rows: dict[str, dict[str, float]],
            imap: dict[str, dict], conv: dict[str, dict]) -> tuple[dict | None, list[str]]:
    totals = {c: 0.0 for c in NUTRIENT_COLS}
    mapped_g = unmapped_g = 0.0
    unmapped: list[str] = []
    salty_unmapped: list[str] = []
    for line in r.get("ingredients", []):
        name = str(line.get("name", "")).strip().lower()
        grams = oc.resolved_grams(line)
        if grams is None:
            continue  # unquantified: excluded, reported via coverage
        entry = imap.get(name)
        per100 = None
        if entry and entry.get("fdc_id") is not None:
            per100 = rows.get(int(entry["fdc_id"]))
        elif entry and entry.get("bundled_id") is not None:
            per100 = core_rows.get(str(entry["bundled_id"]))
        if per100 is None:
            unmapped.append(name)
            unmapped_g += grams
            if any(p in name for p in SALTY_PATTERNS):
                salty_unmapped.append(name)
            continue
        f = grams / 100.0
        for col in NUTRIENT_COLS:
            totals[col] += per100[col] * f
        mapped_g += grams
    total_g = mapped_g + unmapped_g
    coverage = round(mapped_g / total_g, 3) if total_g else 0.0
    if not mapped_g:
        return None, unmapped
    servings = r.get("servings", 1)
    per_serving = {
        "kcal": round(totals["calories"] / servings),
        "protein_g": round(totals["protein"] / servings, 1),
        "carbs_g": round(totals["carbs"] / servings, 1),
        "fat_g": round(totals["fat"] / servings, 1),
        "fiber_g": round(totals["fiber"] / servings, 1),
        "sugar_g": round(totals["sugar"] / servings, 1),
        "sodium_mg": round(totals["sodium"] / servings),
        "coverage": coverage,
        "basis": "USDA FoodData Central values committed in apps/ios/Resources/"
                 "usda_ingredient_catalog.sqlite (matched fdc_id per ingredient in "
                 "tables/nutrition-map.json), plus the app's shipped core-ingredient "
                 "table (data.json) for items without an fdc_id; scaled by evidenced "
                 "gram quantities",
        "unmapped_ingredients": sorted(set(unmapped)),
    }
    if salty_unmapped:
        per_serving["sodium_basis"] = "incomplete-salty-unmapped"
        per_serving["sodium_unmapped_salty"] = sorted(set(salty_unmapped))
    return per_serving, unmapped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true", help="write nutrition_per_serving into files")
    g.add_argument("--check", action="store_true", help="recompute and compare stored values")
    scope = ap.add_mutually_exclusive_group()
    scope.add_argument("--part", default=None)
    scope.add_argument("--all", action="store_true")
    args = ap.parse_args()

    part = None if args.all else args.part
    if args.part and args.part not in oc.PARTS:
        print(f"unknown part {args.part!r}")
        return 2

    rows = catalog_rows()
    core = bundled_core_rows()
    imap, map_errors = load_maps(part)
    conv, _conf = oc.load_conversions(part)
    for e in map_errors:
        print(f"HARD nutrition-map: {e}")

    parts = sorted(oc.PARTS) if part is None else [part]
    n_written = n_checked = mismatches = 0
    for p in parts:
        imap_p, errs = load_maps(p)
        for e in errs:
            print(f"HARD nutrition-map: {e}")
        recipes, bad = oc.discover_recipes(p)
        for path, r in recipes:
            stored = r.get("nutrition_per_serving")
            fresh, _unmapped = compute(r, rows, core, imap_p, conv)
            if args.write:
                if fresh is None:
                    print(f"  {r['id']}: no mapped grams - nothing to write (check nutrition-map.json)")
                    continue
                if stored != fresh:
                    r["nutrition_per_serving"] = fresh
                    path.write_text(json.dumps(r, indent=2, ensure_ascii=False) + "\n")
                    n_written += 1
            else:  # --check
                if fresh is None:
                    if stored is not None:
                        mismatches += 1
                        print(f"MISMATCH {r['id']}: stored block but nothing maps now")
                    continue
                n_checked += 1
                if stored != fresh:
                    mismatches += 1
                    print(f"MISMATCH {r['id']}: stored block disagrees with recompute")
    if args.write:
        print(f"nutrition: wrote {n_written} recipe file(s)")
    else:
        print(f"nutrition check: {n_checked} block(s) verified, {mismatches} mismatch(es)")
    return 1 if (map_errors or mismatches) else 0


if __name__ == "__main__":
    raise SystemExit(main())
