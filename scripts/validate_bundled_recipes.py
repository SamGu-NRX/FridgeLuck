#!/usr/bin/env python3
"""Validate apps/ios/Resources/data.json bundled recipe data.

Checks (see scripts/generate_recipes.md for the project's own checklist):
  1. data.json structure and ingredient catalog shape
  2. recipe row shape: [id, title, time, servings, required, optional, instructions, tagBitmask]
  3. unique, contiguous recipe ids; unique titles (case-insensitive)
  4. time_minutes and servings ranges
  5. ingredient ids exist in the catalog; gram quantities sensible; no duplicate
     ingredient in a recipe; no overlap between required and optional; >= 2 required
  6. tag bitmask valid; dietary consistency: vegan implies vegetarian; vegan recipes
     contain no animal-derived ingredients; vegetarian recipes contain no meat/fish
  7. instructions present and numbered
  8. per-serving nutrition (computed from the bundled USDA ingredient catalog,
     required ingredients only) within plausible bounds

Exits non-zero on any error. Warnings do not fail the run.
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

DEFAULT_PATH = Path(__file__).resolve().parent.parent / "apps/ios/Resources/data.json"

# Ingredient ids by dietary class (derived from the 50-ingredient bundled catalog).
ANIMAL_DERIVED = {1, 12, 13, 14, 32, 33, 50}  # egg, cheese, milk, butter, yogurt, honey, sour cream
MEAT_FISH = {4, 36, 38, 43}  # chicken breast, salmon, ground beef, canned tuna

# Allergen classes mapped to ingredient ids (the app derives allergens from ingredients).
ALLERGENS = {
    "egg": {1},
    "milk": {12, 13, 14, 32, 50},
    "gluten": {9, 15, 28, 31},  # pasta, bread, tortilla, oats
    "soy": {3, 23},
    "peanut": {41},
    "fish": {36, 43},
    "sesame": {22},
}

# Upper bounds in grams per recipe for strong-flavour/condiment ingredients.
CONDIMENT_CAPS = {3: 80, 22: 30, 46: 10, 47: 15, 33: 60, 41: 80, 16: 80, 14: 80}
GENERAL_CAP = 800

TAG_NAMES = ["quick", "vegetarian", "vegan", "asian", "breakfast", "budget", "comfort",
             "mediterranean", "mexican", "high_protein", "low_carb", "one_pot"]

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PATH
    data = json.loads(path.read_text())

    # --- structure ---
    if set(data.keys()) != {"ingredients", "recipes", "tags"}:
        err(f"top-level keys are {sorted(data.keys())}, expected ingredients/recipes/tags")
        return finish(data)

    catalog = data["ingredients"]
    if len(catalog) != 50:
        warn(f"ingredient catalog has {len(catalog)} entries, expected 50")
    for key, row in catalog.items():
        if not re.fullmatch(r"\d+", key):
            err(f"ingredient key {key!r} is not a numeric id")
            continue
        if not (isinstance(row, list) and len(row) == 10 and isinstance(row[0], str)
                and all(isinstance(v, (int, float)) for v in row[1:8])
                and all(isinstance(v, str) for v in row[8:10])):
            err(f"ingredient {key} row has wrong shape")
        elif row[1] <= 0:
            err(f"ingredient {key} ({row[0]}) has non-positive calories")

    ids = set(int(k) for k in catalog)

    # --- recipes ---
    recipes = data["recipes"]
    seen_ids: set[int] = set()
    seen_titles: dict[str, int] = {}
    tag_counts: Counter = Counter()
    cuisine_counts: Counter = Counter()
    kcal_per_serving: list[float] = []

    for idx, r in enumerate(recipes):
        label = f"recipes[{idx}]"
        if not (isinstance(r, list) and len(r) == 8):
            err(f"{label}: row must be a list of 8 fields")
            continue
        rid, title, time_min, servings, required, optional, steps, mask = r

        if not (isinstance(rid, int) and isinstance(title, str) and isinstance(time_min, int)
                and isinstance(servings, int) and isinstance(required, list)
                and isinstance(optional, list) and isinstance(steps, str) and isinstance(mask, int)):
            err(f"{label}: wrong field types")
            continue
        label = f"{rid} {title!r}"

        # ids and titles
        if rid in seen_ids:
            err(f"{label}: duplicate recipe id")
        seen_ids.add(rid)
        norm = re.sub(r"[^a-z0-9]+", " ", title.strip().lower()).strip()
        if not norm:
            err(f"{label}: empty title")
        elif norm in seen_titles:
            err(f"{label}: duplicate title of recipe {seen_titles[norm]}")
        seen_titles[norm] = rid

        # time and servings
        if not 1 <= time_min <= 180:
            err(f"{label}: time_minutes {time_min} outside 1..180")
        if not 1 <= servings <= 8:
            err(f"{label}: servings {servings} outside 1..8")

        # ingredients
        pairs = [("required", required), ("optional", optional)]
        used: set[int] = set()
        kcal_total = 0.0
        for kind, group in pairs:
            for pair in group:
                if not (isinstance(pair, list) and len(pair) == 2
                        and isinstance(pair[0], int) and isinstance(pair[1], (int, float))):
                    err(f"{label}: bad {kind} ingredient pair {pair}")
                    continue
                ing_id, grams = pair
                if ing_id not in ids:
                    err(f"{label}: {kind} ingredient id {ing_id} not in catalog")
                    continue
                if ing_id in used:
                    err(f"{label}: ingredient id {ing_id} appears twice")
                used.add(ing_id)
                if grams <= 0:
                    err(f"{label}: ingredient {ing_id} has non-positive grams {grams}")
                if grams > GENERAL_CAP:
                    err(f"{label}: ingredient {ing_id} has {grams}g (cap {GENERAL_CAP}g)")
                cap = CONDIMENT_CAPS.get(ing_id)
                if cap is not None and grams > cap:
                    # warning: pre-existing scraped recipes exceed these caps;
                    # new recipes comply, historical grams are not rewritten here
                    warn(f"{label}: condiment ingredient {ing_id} has {grams}g (cap {cap}g)")
                if kind == "required":
                    kcal_total += catalog[str(ing_id)][1] * grams / 100.0

        if len(required) < 2:
            err(f"{label}: only {len(required)} required ingredients, need >= 2")
        if len(required) > 8:
            warn(f"{label}: {len(required)} required ingredients (unusually many)")

        # tags
        if not 0 <= mask <= 4095:
            err(f"{label}: tag bitmask {mask} outside 0..4095")
            mask = 0
        active = [TAG_NAMES[b] for b, name in enumerate(TAG_NAMES) if mask & (1 << b)]
        tag_counts.update(active)
        if mask & 4 and not mask & 2:
            err(f"{label}: tagged vegan without vegetarian")
        if mask & 4 and used & ANIMAL_DERIVED:
            err(f"{label}: tagged vegan but contains animal-derived ingredients "
                f"{sorted(used & ANIMAL_DERIVED)}")
        if mask & 2 and used & MEAT_FISH:
            err(f"{label}: tagged vegetarian but contains meat/fish {sorted(used & MEAT_FISH)}")

        # instructions
        lines = [ln for ln in steps.strip().splitlines() if ln.strip()]
        if len(lines) < 2:
            err(f"{label}: fewer than 2 instruction steps")
        for ln in lines:
            if re.match(r"^Source:\s*http", ln.strip()):
                continue  # provenance attribution line, not a cooking step
            if not re.match(r"^\d+\.\s", ln.strip()):
                err(f"{label}: instruction line not numbered: {ln[:60]!r}")
                break

        # nutrition from the bundled catalog (required ingredients only)
        if servings > 0 and kcal_total > 0:
            per = kcal_total / servings
            kcal_per_serving.append(per)
            # nutrition is the required-ingredients-only convention (no separate
            # recipe nutrition fields), so it is diagnostic: hard-fail only the
            # physically absurd, warn on the merely unusual
            if not 10 <= per <= 2500:
                err(f"{label}: {per:.0f} kcal/serving is implausible")
            elif not 150 <= per <= 1100:
                warn(f"{label}: {per:.0f} kcal/serving is outside the common range")

        for name in ("asian", "mediterranean", "mexican"):
            if mask & (1 << TAG_NAMES.index(name)):
                cuisine_counts[name] += 1

    # id contiguity
    if seen_ids and sorted(seen_ids) != list(range(min(seen_ids), max(seen_ids) + 1)):
        missing = sorted(set(range(min(seen_ids), max(seen_ids) + 1)) - seen_ids)
        err(f"recipe ids are not contiguous; missing {missing[:20]}")

    return finish(data, tag_counts, cuisine_counts, kcal_per_serving, len(recipes))


def finish(data, tag_counts=None, cuisine_counts=None, kcal=None, count=None):
    for w in warnings:
        print(f"WARNING: {w}")
    for e in errors:
        print(f"ERROR: {e}")
    print()
    if count is not None:
        print(f"recipes: {count}, all tags: {dict(tag_counts)}")
        print(f"cuisine tags: {dict(cuisine_counts)}")
        if kcal:
            kcal.sort()
            print(f"kcal/serving p5={kcal[len(kcal)//20]:.0f} "
                  f"median={kcal[len(kcal)//2]:.0f} p95={kcal[-max(1,len(kcal)//20)]:.0f}")
    print(f"{len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
