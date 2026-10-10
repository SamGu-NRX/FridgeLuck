#!/usr/bin/env python3
"""Verify the live production replay against the transcribed production arm.

The live arm (production/Sources/PantryFeasibilityProduction) runs the REAL
RecipeRepository.findMakeable / findNearMatch on one real migrated in-memory
database per corpus state — no transcription. This checker asserts that the
transcribed production arm in the replay (verify_replay.py) matches it exactly,
per state, for both result sets:

- makeable_ids: findMakeable(with: state.available_ids, profile) output
- near_match_ids: findNearMatch(..., maxMissingRequired: 3) output

Writes runs/production_verification.json. Exit 1 on any mismatch.

Note the direction of the quantity gap: production ignores grams entirely, so
both arms and the live run agree exactly; the gap to the data-model oracle is
reported by run_eval.py from the (transcribed) per-pair rows.
"""

import json
import sys
from pathlib import Path

from oracle import Catalog, DIET_EXCLUDED_IDS, DIET_TAG_MASK
from verify_replay import CORE_MEMBERSHIPS

MAX_MISSING_REQUIRED = 3


def production_sets(state: dict, catalog: Catalog) -> tuple[set, set]:
    """Transcription of RecipeRepository.findMakeable/findNearMatch output sets."""
    profile = state["profile"]
    diet = (profile["diet"] or "").strip().lower()
    selected_groups = set(g.strip().lower() for g in profile["allergen_groups"])
    excluded = set(profile["allergen_ingredient_ids"])
    for ingredient_id, member_groups in CORE_MEMBERSHIPS.items():
        if member_groups & selected_groups:
            excluded.add(ingredient_id)
    excluded |= DIET_EXCLUDED_IDS.get(diet, set())
    available = set(state["available_ids"])
    required_mask = DIET_TAG_MASK.get(diet, 0)

    makeable: set[int] = set()
    near_match: set[int] = set()
    if not available:
        return makeable, near_match

    for recipe in catalog.recipes.values():
        required_ids = [i for i, _ in recipe.required]
        optional_ids = [i for i, _ in recipe.optional]
        missing = sum(1 for i in required_ids if i not in available)
        tag_ok = not required_mask or (recipe.tags & required_mask) == required_mask
        excluded_hit = any(i in excluded for i in required_ids + optional_ids)
        if not tag_ok or excluded_hit:
            continue
        if missing == 0:
            makeable.add(recipe.recipe_id)
        elif missing <= MAX_MISSING_REQUIRED:
            near_match.add(recipe.recipe_id)
    return makeable, near_match


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_production.py <corpus_dir>", file=sys.stderr)
        return 2
    corpus = Path(sys.argv[1])
    catalog = Catalog.load(corpus / "catalog_snapshot.json")

    states: dict[int, dict] = {}
    with (corpus / "states.jsonl").open(encoding="utf-8") as f:
        for line in f:
            state = json.loads(line)
            states[state["state_id"]] = state

    mismatches: list[str] = []
    makeable_agree = 0
    near_agree = 0
    rows = 0
    with (corpus / "production_replay.jsonl").open(encoding="utf-8") as f:
        for line in f:
            row = json.loads(line)
            state = states[row["state_id"]]
            rows += 1
            want_makeable, want_near = production_sets(state, catalog)
            if set(row["makeable_ids"]) == want_makeable:
                makeable_agree += 1
            else:
                mismatches.append(
                    f"state {row['state_id']} makeable: live "
                    f"{len(row['makeable_ids'])} vs transcribed {len(want_makeable)}")
            if set(row["near_match_ids"]) == want_near:
                near_agree += 1
            else:
                mismatches.append(
                    f"state {row['state_id']} near_match: live "
                    f"{len(row['near_match_ids'])} vs transcribed {len(want_near)}")

    if rows != len(states):
        mismatches.append(f"row count {rows} != {len(states)} states")

    verification = {
        "production_live_states": rows,
        "makeable_set_agreement": makeable_agree,
        "near_match_set_agreement": near_agree,
        "agreement_rate": (
            (makeable_agree + near_agree) / (2 * rows) if rows else 0.0),
        "note": (
            "live RecipeRepository.findMakeable/findNearMatch on real migrated "
            "in-memory databases vs the transcribed production arm"),
        "mismatches": mismatches[:20],
    }
    out = corpus / "production_verification.json"
    out.write_text(json.dumps(verification, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(verification, indent=1))

    if mismatches:
        print(f"FAILED: {len(mismatches)} mismatches", file=sys.stderr)
        return 1
    print(f"production live arm matches the transcription on all {rows} states")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
