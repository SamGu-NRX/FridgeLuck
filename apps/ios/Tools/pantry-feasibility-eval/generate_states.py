#!/usr/bin/env python3
"""Freeze seeded pantry/profile states for the pantry-feasibility evaluation.

Generates a deterministic corpus of states (default 5,200, seed 20261010)
covering: quantities (known, unknown/estimated, zero/exhausted, exact
boundaries), required/optional ingredient distinctions, explicit allergen
groups and individual allergen IDs, every supported diet, and empty sets
(empty pantry, no allergens, no diet). Also freezes a catalog snapshot from
apps/ios/Resources/data.json with provenance.

Usage:
  python3 generate_states.py [--recipe-root /path/to/repo] [--count N] [--seed S]

Outputs (in runs/):
  catalog_snapshot.json  - frozen recipe/ingredient data + provenance
  states.jsonl           - one JSON state per line
  manifest.json          - counts, hashes, coverage summary
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
from pathlib import Path

from oracle import (
    CORE_MEMBERSHIPS,
    GROUP_IDS,
    Catalog,
    sha256_file,
)

DIETS = ["", "vegan", "vegetarian", "pescatarian", "keto"]
GOALS = ["general", "weight_loss", "muscle_gain", "maintenance"]

# Families and their target counts (total 5,200).
FAMILY_COUNTS = {
    "realistic_mix": 2080,
    "boundary_quantities": 780,
    "near_match_surfaces": 780,
    "planted_false_complete": 520,
    "agreement_probe": 260,
    "all_unknown_quantities": 416,
    "diet_allergen_matrix": 260,
    "empty_pantry": 104,
}


def default_repo_root() -> Path:
    # .../apps/ios/Tools/pantry-feasibility-eval -> .../apps/ios
    return Path(__file__).resolve().parents[2]


def build_catalog(repo_root: Path) -> Catalog:
    data_path = repo_root / "Resources" / "data.json"
    raw = json.loads(data_path.read_text(encoding="utf-8"))

    ingredient_names: dict[int, str] = {}
    for id_string, row in raw["ingredients"].items():
        # ingredient rows are positional arrays: [name, kcal, protein_g,
        # fat_g, carbs_g, ...] - the display name is the first element
        ingredient_names[int(id_string)] = row[0]

    from oracle import RecipeRow


    parsed: dict[int, RecipeRow] = {}
    for r in raw["recipes"]:
        parsed[int(r[0])] = RecipeRow(
            recipe_id=int(r[0]),
            title=r[1],
            time_minutes=int(r[2]),
            tags=int(r[7]),
            required=tuple((int(i), float(g)) for i, g in r[4]),
            optional=tuple((int(i), float(g)) for i, g in r[5]),
        )

    catalog = Catalog(
        recipes=parsed,
        ingredient_names=ingredient_names,
        source_sha256=sha256_file(data_path),
    )
    return catalog


def catalog_stats(catalog: Catalog) -> dict:
    used = set()
    for r in catalog.recipes.values():
        used |= {i for i, _ in r.required}
        used |= {i for i, _ in r.optional}
    return {
        "recipe_count": len(catalog.recipes),
        "ingredient_ids_used": sorted(used),
        "max_ingredient_id_used": max(used),
        "all_within_core_50": max(used) <= 50,
    }


def pick_profile(rng: random.Random) -> dict:
    diet = rng.choice(DIETS)
    # Group selections: none, single, or a plausible pair. Always canonical IDs
    # (unknown group strings are production-dropped; the matrix family plants
    # one of those separately).
    group_choices = [
        [],
        ["milk"],
        ["egg"],
        ["peanut"],
        ["tree_nut"],
        ["wheat_gluten"],
        ["soy"],
        ["fish"],
        ["sesame"],
        ["milk", "egg"],
        ["gluten_free_placeholder"],  # non-canonical: must be dropped, never honored
    ]
    groups = rng.choice(group_choices)
    individual = rng.choice([[], [], [], [44], [20], [6], [44, 20]])
    version = 0 if (not groups and rng.random() < 0.5) else 1
    return {
        "diet": diet if diet else None,
        "allergen_groups": groups,
        "allergen_ingredient_ids": individual,
        "allergen_preferences_version": version,
        "goal": rng.choice(GOALS),
    }


def lot(ingredient_id: int, grams: float | None, is_estimate: bool) -> dict:
    if is_estimate:
        return {"ingredient_id": ingredient_id, "known_grams": None, "is_estimate": True}
    return {"ingredient_id": ingredient_id, "known_grams": round(grams, 1), "is_estimate": False}


def make_pantry(
    rng: random.Random,
    catalog: Catalog,
    size: int,
    *,
    quantity_mode: str,
    target_recipe_ids: list[int] | None = None,
) -> list[dict]:
    """Build a pantry across the core 50 IDs with the requested quantity mode."""
    core_ids = sorted(CORE_MEMBERSHIPS.keys())
    chosen = rng.sample(core_ids, min(size, len(core_ids)))
    pantry: list[dict] = []
    requirements: dict[int, float] = {}
    if target_recipe_ids:
        for rid in target_recipe_ids:
            recipe = catalog.recipes[rid]
            for ingredient_id, grams in recipe.required:
                requirements[ingredient_id] = max(requirements.get(ingredient_id, 0.0), grams)

    for ingredient_id in chosen:
        roll = rng.random()
        if quantity_mode == "all_unknown":
            pantry.append(lot(ingredient_id, None, True))
            continue

        if roll < 0.15:
            # estimated (unknown) quantity
            pantry.append(lot(ingredient_id, None, True))
        elif roll < 0.20:
            # exhausted lot: known zero remaining, item is gone
            pantry.append(lot(ingredient_id, 0.0, False))
        else:
            base = requirements.get(ingredient_id)
            if base:
                # plausibly around what recipes need
                grams = base * rng.uniform(0.3, 3.0)
            else:
                grams = rng.choice([15.0, 40.0, 90.0, 150.0, 250.0, 500.0, 1000.0])
            pantry.append(lot(ingredient_id, grams, False))
    return pantry


def state_dict(
    state_id: int,
    family: str,
    profile: dict,
    pantry: list[dict],
    available_ids: set[int],
) -> dict:
    return {
        "state_id": state_id,
        "family": family,
        "profile": profile,
        "pantry": pantry,
        "available_ids": sorted(available_ids),
    }


def sufficient_pantry_for(
    rng: random.Random, catalog: Catalog, recipe_ids: list[int], unknown_ids: set[int] | None = None
) -> list[dict]:
    """Pantry that satisfies every required row of the given recipes."""
    unknown_ids = unknown_ids or set()
    requirements: dict[int, float] = {}
    for rid in recipe_ids:
        for ingredient_id, grams in catalog.recipes[rid].required:
            requirements[ingredient_id] = max(requirements.get(ingredient_id, 0.0), grams)

    pantry = []
    for ingredient_id, needed in sorted(requirements.items()):
        if ingredient_id in unknown_ids:
            pantry.append(lot(ingredient_id, None, True))
        else:
            pantry.append(lot(ingredient_id, needed * rng.uniform(1.2, 3.0), False))
    # a few optional-flavored extras
    extras = rng.sample(sorted(CORE_MEMBERSHIPS.keys()), 5)
    for ingredient_id in extras:
        if ingredient_id not in requirements:
            pantry.append(lot(ingredient_id, rng.choice([30.0, 120.0, 300.0]), False))
    return pantry


def generate(catalog: Catalog, total_target: dict[str, int], seed: int) -> list[dict]:
    rng = random.Random(seed)
    all_recipe_ids = sorted(catalog.recipes.keys())
    core_ids = sorted(CORE_MEMBERSHIPS.keys())

    states: list[dict] = []
    state_id = 0

    def next_id() -> int:
        nonlocal state_id
        state_id += 1
        return state_id

    # -- empty_pantry: empty set, varied profiles --
    for _ in range(total_target["empty_pantry"]):
        state_id = next_id()
        states.append(
            state_dict(
                state_id,
                "empty_pantry",
                pick_profile(rng),
                [],
                set(),
            )
        )

    # -- planted_false_complete: everything sufficient EXCEPT one required
    # ingredient with a known short amount. Production (by ID-membership
    # semantics) will call these recipes complete matches; the oracle must
    # call them infeasible with insufficient_known_quantity. --
    for _ in range(total_target["planted_false_complete"]):
        state_id = next_id()
        recipe = catalog.recipes[rng.choice(all_recipe_ids)]
        ingredient_id, required_grams = rng.choice(
            [row for row in recipe.required if row[1] > 0] or recipe.required
        )
        profile = pick_profile(rng)
        # keep the plant clean: no exclusions that would mask the quantity gap
        profile["diet"] = None
        profile["allergen_groups"] = []
        profile["allergen_ingredient_ids"] = []
        ratio = rng.choice([0.1, 0.25, 0.5, 0.75, 0.9, 0.99])
        # strictly below required with NO gram floor: a floor (e.g. 1g) would
        # silently satisfy sub-gram requirements and un-plant the state.
        # Floor at the lot precision (1 decimal): round() could push 4.95 -> 5.0
        # and make the plant sufficient again.
        available_grams = math.floor(required_grams * ratio * 10) / 10
        pantry = []
        for other_id, grams in recipe.required:
            if other_id == ingredient_id:
                pantry.append(lot(other_id, available_grams, False))
            else:
                pantry.append(lot(other_id, grams * rng.uniform(1.2, 2.5), False))
        for other_id, grams in rng.sample(recipe.optional, min(2, len(recipe.optional))):
            pantry.append(lot(other_id, grams, False))
        available = {entry["ingredient_id"] for entry in pantry}
        states.append(
            state_dict(state_id, "planted_false_complete", profile, pantry, available)
        )

    # -- boundary_quantities: amounts exactly at, +/-1g, and +/-10% of the
    # required grams. Pins the >= comparison and float noise. --
    for _ in range(total_target["boundary_quantities"]):
        state_id = next_id()
        recipe = catalog.recipes[rng.choice(all_recipe_ids)]
        profile = pick_profile(rng)
        profile["diet"] = None
        profile["allergen_groups"] = []
        profile["allergen_ingredient_ids"] = []
        pantry = []
        for other_id, grams in recipe.required:
            mode = rng.choice(["exact", "minus_1", "plus_1", "minus_10pct", "plus_10pct"])
            if mode == "exact":
                amount = grams
            elif mode == "minus_1":
                amount = max(0.0, grams - 1.0)
            elif mode == "plus_1":
                amount = grams + 1.0
            elif mode == "minus_10pct":
                amount = grams * 0.9
            else:
                amount = grams * 1.1
            pantry.append(lot(other_id, amount, False))
        available = {entry["ingredient_id"] for entry in pantry}
        states.append(state_dict(state_id, "boundary_quantities", profile, pantry, available))

    # -- near_match_surfaces: exactly one required ingredient absent (by ID),
    # everything else sufficient. Exercises near-match explanations. --
    for _ in range(total_target["near_match_surfaces"]):
        state_id = next_id()
        recipe = catalog.recipes[rng.choice(all_recipe_ids)]
        if len(recipe.required) < 2:
            # need one to remove while keeping the rest meaningful
            recipe = catalog.recipes[rng.choice([r for r in all_recipe_ids
                                                 if len(catalog.recipes[r].required) >= 2])]
        profile = pick_profile(rng)
        profile["diet"] = None
        profile["allergen_groups"] = []
        profile["allergen_ingredient_ids"] = []
        absent_id, _ = rng.choice(recipe.required)
        pantry = []
        for other_id, grams in recipe.required:
            if other_id == absent_id:
                continue
            pantry.append(lot(other_id, grams * rng.uniform(1.2, 2.5), False))
        for other_id, grams in rng.sample(recipe.optional, min(2, len(recipe.optional))):
            pantry.append(lot(other_id, grams, False))
        available = {entry["ingredient_id"] for entry in pantry}
        states.append(state_dict(state_id, "near_match_surfaces", profile, pantry, available))

    # -- agreement_probe: fully sufficient, exclusion-free pantries so both
    # production and the oracle should agree the recipe is feasible. --
    for _ in range(total_target["agreement_probe"]):
        state_id = next_id()
        recipe = catalog.recipes[rng.choice(all_recipe_ids)]
        profile = pick_profile(rng)
        profile["diet"] = None
        profile["allergen_groups"] = []
        profile["allergen_ingredient_ids"] = []
        pantry = sufficient_pantry_for(rng, catalog, [recipe.recipe_id])
        available = {entry["ingredient_id"] for entry in pantry}
        states.append(state_dict(state_id, "agreement_probe", profile, pantry, available))

    # -- all_unknown_quantities: every lot is an estimate (unknown amount).
    # Presence-only surface; oracle records quantity assumptions, never grams. --
    for _ in range(total_target["all_unknown_quantities"]):
        state_id = next_id()
        recipe = catalog.recipes[rng.choice(all_recipe_ids)]
        profile = pick_profile(rng)
        profile["diet"] = None
        profile["allergen_groups"] = []
        profile["allergen_ingredient_ids"] = []
        pantry = sufficient_pantry_for(rng, catalog, [recipe.recipe_id],
                                       unknown_ids={i for i, _ in recipe.required})
        available = {entry["ingredient_id"] for entry in pantry}
        states.append(state_dict(state_id, "all_unknown_quantities", profile, pantry, available))

    # -- diet_allergen_matrix: every diet crossed with group selections,
    # including empty groups and legacy (version 0) profiles. --
    matrix_combos = [
        ([], 0),
        ([], 1),
        (["milk"], 1),
        (["egg"], 1),
        (["fish"], 1),
        (["soy"], 1),
        (["wheat_gluten"], 1),
        (["peanut"], 1),
        (["tree_nut"], 1),
        (["sesame"], 1),
        (["shellfish"], 1),
        (["mustard"], 1),
        (["milk", "egg"], 1),
        (["gluten_free_placeholder"], 1),  # non-canonical, dropped in production
    ]
    for _ in range(total_target["diet_allergen_matrix"]):
        state_id = next_id()
        groups, version = rng.choice(matrix_combos)
        profile = {
            "diet": rng.choice(DIETS) or None,
            "allergen_groups": groups,
            "allergen_ingredient_ids": rng.choice([[], [12], [36], [41], [49]]),
            "allergen_preferences_version": version,
            "goal": rng.choice(GOALS),
        }
        recipe = catalog.recipes[rng.choice(all_recipe_ids)]
        pantry = make_pantry(rng, catalog, rng.randint(6, 18), quantity_mode="mixed",
                             target_recipe_ids=[recipe.recipe_id])
        available = {entry["ingredient_id"] for entry in pantry if entry["known_grams"] != 0
                     or entry["is_estimate"]}
        states.append(state_dict(state_id, "diet_allergen_matrix", profile, pantry, available))

    # -- realistic_mix: general-population pantries, mixed quantity states,
    # full profile variety. --
    while len(states) < sum(total_target.values()):
        state_id = next_id()
        profile = pick_profile(rng)
        size = rng.randint(2, 24)
        pantry = make_pantry(rng, catalog, size, quantity_mode="mixed")
        available = {entry["ingredient_id"] for entry in pantry if entry["known_grams"] != 0
                     or entry["is_estimate"]}
        states.append(state_dict(state_id, "realistic_mix", profile, pantry, available))

    states.sort(key=lambda s: s["state_id"])
    return states


def coverage_summary(states: list[dict], catalog: Catalog) -> dict:
    families: dict[str, int] = {}
    diets: dict[str, int] = {}
    group_sets = set()
    with_empty_pantry = 0
    with_unknown_quantity = 0
    with_known_quantity = 0
    with_zero_remaining = 0
    version_0 = 0
    version_1 = 0
    empty_available = 0
    for state in states:
        families[state["family"]] = families.get(state["family"], 0) + 1
        diet = state["profile"]["diet"] or "none"
        diets[diet] = diets.get(diet, 0) + 1
        group_sets.add(tuple(sorted(state["profile"]["allergen_groups"])))
        if not state["pantry"]:
            with_empty_pantry += 1
        if not state["available_ids"]:
            empty_available += 1
        if state["profile"]["allergen_preferences_version"] == 0:
            version_0 += 1
        else:
            version_1 += 1
        for entry in state["pantry"]:
            if entry["is_estimate"]:
                with_unknown_quantity += 1
                break
        else:
            if state["pantry"]:
                for entry in state["pantry"]:
                    if not entry["is_estimate"]:
                        with_known_quantity += 1
                        break
        for entry in state["pantry"]:
            if not entry["is_estimate"] and entry["known_grams"] == 0:
                with_zero_remaining += 1
                break
    return {
        "state_count": len(states),
        "families": families,
        "diets": diets,
        "distinct_allergen_group_selections": len(group_sets),
        "states_with_empty_pantry": with_empty_pantry,
        "states_with_empty_available_set": empty_available,
        "states_with_unknown_quantity_lots": with_unknown_quantity,
        "states_with_known_quantity_lots": with_known_quantity,
        "states_with_zero_remaining_lots": with_zero_remaining,
        "profiles_version_0": version_0,
        "profiles_version_1": version_1,
    }


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for row in rows:
            f.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe-root", type=Path, default=default_repo_root())
    parser.add_argument("--seed", type=int, default=20261010)
    parser.add_argument("--count", type=int, default=None,
                        help="Override total state count (scales families proportionally).")
    args = parser.parse_args()

    tool_dir = Path(__file__).resolve().parent
    runs_dir = tool_dir / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)

    catalog = build_catalog(args.recipe_root)

    targets = dict(FAMILY_COUNTS)
    if args.count:
        total = sum(FAMILY_COUNTS.values())
        targets = {
            family: max(1, round(count * args.count / total))
            for family, count in FAMILY_COUNTS.items()
        }

    states = generate(catalog, targets, args.seed)

    # catalog snapshot
    snapshot = catalog.to_dict()
    snapshot["provenance"] = {
        "source": "apps/ios/Resources/data.json",
        "source_sha256": catalog.source_sha256,
        "generator_seed": args.seed,
        "note": (
            "Frozen extract of the bundled recipe catalog. The oracle reads only "
            "this snapshot; the SwiftReplay harness reads the same data.json "
            "through the production loader and cross-checks counts."
        ),
    }
    snapshot_path = runs_dir / "catalog_snapshot.json"
    with open(snapshot_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(snapshot, f, sort_keys=True, indent=1)
        f.write("\n")

    states_path = runs_dir / "states.jsonl"
    write_jsonl(states_path, states)

    manifest = {
        "seed": args.seed,
        "state_count": len(states),
        "coverage": coverage_summary(states, catalog),
        "catalog": catalog_stats(catalog),
        "states_sha256": sha256_file(states_path),
        "catalog_snapshot_sha256": sha256_file(snapshot_path),
        "constraint_coverage_guarantees": [
            "states with empty pantry and empty available set",
            "states with unknown (estimated) quantities preserved as unknown",
            "states with known zero remaining (exhausted) lots",
            "boundary quantities at exactly, +/-1g, and +/-10% of required grams",
            "planted false-complete states (known short required quantity)",
            "all canonical allergen groups selected at least once",
            "non-canonical allergen group strings (must be dropped, not honored)",
            "all supported diets, including legacy version-0 profiles",
            "required/optional rows both present in every state's surface",
        ],
    }
    with open(runs_dir / "manifest.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, sort_keys=True, indent=1)
        f.write("\n")

    print(f"states: {len(states)} -> {states_path}")
    print(f"catalog: {len(catalog.recipes)} recipes -> {snapshot_path}")
    print(json.dumps(manifest["coverage"], indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
