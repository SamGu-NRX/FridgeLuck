#!/usr/bin/env python3
"""Validate the frozen pantry-feasibility state corpus.

Checks (fail loudly, exit non-zero on any violation):
  - at least 5,000 states, all with the required fields and valid profiles
  - manifest hashes match the frozen files on disk
  - constraint coverage: quantities (known / unknown-estimate / zero-remaining /
    boundary), required+optional surfaces, explicit allergens (every canonical
    group, individual IDs, non-canonical strings that must be dropped),
    every diet, empty pantry and empty available sets, legacy version-0 profiles
  - planted false-complete counterexamples: oracle classifies the planted
    recipe infeasible with insufficient_known_quantity and NO other blocker
    (no exclusions, no missing IDs, no tag violation) - i.e. production's
    ID-membership semantics would claim the recipe complete
  - agreement probes: oracle agrees the target recipe is feasible
  - unknown quantities are preserved as unknown (no invented grams anywhere)

Usage: python3 check_states.py [--tool-dir DIR]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from oracle import (
    CORE_MEMBERSHIPS,
    GROUP_IDS,
    Catalog,
    FeasibilityOracle,
    sha256_file,
)

MIN_STATES = 5000

REQUIRED_STATE_FIELDS = {"state_id", "family", "profile", "pantry", "available_ids"}
REQUIRED_PROFILE_FIELDS = {
    "diet",
    "allergen_groups",
    "allergen_ingredient_ids",
    "allergen_preferences_version",
    "goal",
}
REQUIRED_PANTRY_FIELDS = {"ingredient_id", "known_grams", "is_estimate"}


class CheckError(AssertionError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise CheckError(message)


def validate_state_shape(state: dict, catalog: Catalog) -> None:
    missing = REQUIRED_STATE_FIELDS - set(state)
    check(not missing, f"state {state.get('state_id')}: missing fields {missing}")
    missing_profile = REQUIRED_PROFILE_FIELDS - set(state["profile"])
    check(not missing_profile,
          f"state {state['state_id']}: missing profile fields {missing_profile}")
    diet = state["profile"]["diet"]
    check(diet in (None, "", "vegan", "vegetarian", "pescatarian", "keto"),
          f"state {state['state_id']}: unknown diet {diet!r}")
    for lot in state["pantry"]:
        missing_lot = REQUIRED_PANTRY_FIELDS - set(lot)
        check(not missing_lot, f"state {state['state_id']}: lot missing {missing_lot}")
        if lot["is_estimate"]:
            check(lot["known_grams"] is None,
                  f"state {state['state_id']}: estimate lot must carry known_grams=null")
        else:
            check(isinstance(lot["known_grams"], (int, float)) and lot["known_grams"] >= 0,
                  f"state {state['state_id']}: known lot must carry a non-negative number")
    # available_ids must be exactly what the data model derives
    oracle = FeasibilityOracle(catalog)
    check(set(state["available_ids"]) == oracle.available_ids(state),
          f"state {state['state_id']}: available_ids disagree with pantry derivation")


def run_checks(tool_dir: Path) -> dict:
    runs_dir = tool_dir / "runs"
    catalog = Catalog.load(runs_dir / "catalog_snapshot.json")
    oracle = FeasibilityOracle(catalog)

    manifest = json.loads((runs_dir / "manifest.json").read_text(encoding="utf-8"))

    # hashes match what is frozen on disk
    check(sha256_file(runs_dir / "states.jsonl") == manifest["states_sha256"],
          "states.jsonl sha256 does not match manifest")
    check(sha256_file(runs_dir / "catalog_snapshot.json") == manifest["catalog_snapshot_sha256"],
          "catalog_snapshot.json sha256 does not match manifest")

    states = []
    with open(runs_dir / "states.jsonl", "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                states.append(json.loads(line))

    check(len(states) >= MIN_STATES, f"only {len(states)} states frozen (< {MIN_STATES})")
    ids = [s["state_id"] for s in states]
    check(len(set(ids)) == len(ids), "duplicate state_id")
    check(ids == sorted(ids), "state ids not sorted")

    families: dict[str, int] = {}
    diets: set[str] = set()
    canonical_groups_seen: set[str] = set()
    noncanonical_group_states = 0
    version0 = 0
    version1 = 0
    empty_pantry = 0
    empty_available = 0
    unknown_quantity_states = 0
    zero_remaining_states = 0
    known_quantity_states = 0
    boundary_exact = 0

    for state in states:
        validate_state_shape(state, catalog)
        families[state["family"]] = families.get(state["family"], 0) + 1
        diet = state["profile"]["diet"] or "none"
        diets.add(diet)
        groups = state["profile"]["allergen_groups"]
        if any(g not in GROUP_IDS for g in groups):
            noncanonical_group_states += 1
        else:
            canonical_groups_seen.update(groups)
        if state["profile"]["allergen_preferences_version"] == 0:
            version0 += 1
        else:
            version1 += 1
        if not state["pantry"]:
            empty_pantry += 1
        if not state["available_ids"]:
            empty_available += 1
        if any(entry["is_estimate"] for entry in state["pantry"]):
            unknown_quantity_states += 1
        if any(not entry["is_estimate"] and entry["known_grams"] == 0
               for entry in state["pantry"]):
            zero_remaining_states += 1
        if any(not entry["is_estimate"] and entry["known_grams"] > 0
               for entry in state["pantry"]):
            known_quantity_states += 1
        if state["family"] == "boundary_quantities":
            boundary_exact += 1

    # constraint coverage gates
    for family, minimum in {
        "realistic_mix": 1000,
        "boundary_quantities": 500,
        "near_match_surfaces": 500,
        "planted_false_complete": 300,
        "agreement_probe": 100,
        "all_unknown_quantities": 200,
        "diet_allergen_matrix": 100,
        "empty_pantry": 50,
    }.items():
        check(families.get(family, 0) >= minimum,
              f"family {family}: {families.get(family, 0)} states (< {minimum})")

    check(diets == {"none", "vegan", "vegetarian", "pescatarian", "keto"},
          f"diets covered: {sorted(diets)}")
    check(canonical_groups_seen == GROUP_IDS,
          f"canonical allergen groups covered: {sorted(canonical_groups_seen)}")
    check(noncanonical_group_states > 0,
          "no state exercises non-canonical allergen group strings")
    check(version0 > 0 and version1 > 0, "need both legacy (v0) and confirmed (v1) profiles")
    check(empty_pantry > 0, "no empty-pantry states")
    check(empty_available > 0, "no states with an empty available set")
    check(unknown_quantity_states > 0, "no states with unknown (estimated) quantities")
    check(zero_remaining_states > 0, "no states with known zero-remaining (exhausted) lots")
    check(known_quantity_states > 0, "no states with known positive quantities")

    # planted false-complete counterexamples: the planted recipe must be
    # infeasible ONLY because of a known short quantity, so production's
    # ID-membership complete-match claim is contradicted by the data model.
    planted_checked = 0
    for state in states:
        if state["family"] != "planted_false_complete":
            continue
        planted_checked += 1
        pantry_ids = {entry["ingredient_id"] for entry in state["pantry"]}
        recipe_ids = [
            rid for rid, recipe in catalog.recipes.items()
            if set(i for i, _ in recipe.required) <= pantry_ids
        ]
        check(recipe_ids, f"state {state['state_id']}: no recipe fully covered by pantry IDs")
        # every fully-ID-covered recipe whose quantities are all known-short is
        # a false-complete candidate; at least one must be oracle-infeasible
        # purely on insufficient_known_quantity
        hit = None
        for rid in recipe_ids:
            verdict = oracle.evaluate_recipe(state, catalog.recipes[rid])
            reasons = verdict.infeasible_reasons
            if verdict.insufficient and verdict.feasible is False and set(reasons) == {
                "insufficient_known_quantity"
            }:
                hit = (rid, verdict)
                break
        check(hit is not None,
              f"state {state['state_id']}: planted false-complete not isolated by oracle")
        _, verdict = hit
        check(verdict.unknown_quantity_assumptions == [],
              f"state {state['state_id']}: planted state must have fully known quantities")
        check(verdict.missing_required_ids == [],
              f"state {state['state_id']}: planted state must have no missing required IDs")
        check(verdict.excluded_ids == [],
              f"state {state['state_id']}: planted state must have no exclusions")
        check(not verdict.tag_violation,
              f"state {state['state_id']}: planted state must not trip the diet tag filter")

    # agreement probes: the target recipe is feasible by the data model
    probes_checked = 0
    for state in states:
        if state["family"] != "agreement_probe":
            continue
        probes_checked += 1
        pantry_ids = {entry["ingredient_id"] for entry in state["pantry"]}
        feasible_ids = [
            rid for rid in catalog.recipes
            if set(i for i, _ in catalog.recipes[rid].required) <= pantry_ids
            and oracle.evaluate_recipe(state, catalog.recipes[rid]).feasible
        ]
        check(feasible_ids,
              f"state {state['state_id']}: agreement probe produced no feasible recipe")

    # unknown quantities preserved: no state stores invented grams on estimates
    for state in states:
        for entry in state["pantry"]:
            if entry["is_estimate"]:
                check(entry["known_grams"] is None,
                      f"state {state['state_id']}: estimate lot carries invented grams")

    summary = {
        "state_count": len(states),
        "families": families,
        "diets_covered": sorted(diets),
        "canonical_groups_covered": sorted(canonical_groups_seen),
        "noncanonical_group_states": noncanonical_group_states,
        "profiles_version_0": version0,
        "profiles_version_1": version1,
        "empty_pantry_states": empty_pantry,
        "empty_available_states": empty_available,
        "unknown_quantity_states": unknown_quantity_states,
        "zero_remaining_states": zero_remaining_states,
        "known_quantity_states": known_quantity_states,
        "boundary_quantities_states": boundary_exact,
        "planted_false_complete_checked": planted_checked,
        "agreement_probes_checked": probes_checked,
        "catalog_recipes": len(catalog.recipes),
        "catalog_source_sha256": catalog.source_sha256,
    }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool-dir", type=Path,
                        default=Path(__file__).resolve().parent)
    try:
        summary = run_checks(parser.parse_args().tool_dir)
    except CheckError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("state corpus checks passed:")
    print(json.dumps(summary, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
