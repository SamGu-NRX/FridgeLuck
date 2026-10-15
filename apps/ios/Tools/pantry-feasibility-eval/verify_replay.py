#!/usr/bin/env python3
"""Cross-check the Swift replay against the Python oracle.

1. Membership sync: the vendored production `AllergenExclusions` table
   (exported from Swift as JSON) must match `CORE_MEMBERSHIPS` in oracle.py
   on IDs, bundled names, and group sets. Drift here means the vendored file
   no longer matches the Python transcription of it.
2. Oracle agreement: for every (state, recipe) pair in the Swift replay
   output, `oracle.py` must produce the identical verdict.
3. Production arm: an independent Python transcription of the production
   ID-membership predicate must agree with the Swift `production_makeable`.

Usage: python3 verify_replay.py [--tool-dir DIR] [--results replay.jsonl]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from oracle import (
    CORE_MEMBERSHIPS,
    DIET_EXCLUDED_IDS,
    DIET_TAG_MASK,
    Catalog,
    FeasibilityOracle,
    RecipeRow,
)


def production_verdict(state: dict, recipe: RecipeRow) -> bool:
    """Independent transcription of RecipeRepository.findMakeable semantics.

    Effective exclusions mirror `HealthProfile.effectiveAllergenExclusionIds`:
    explicit ingredient IDs plus every member of a selected allergen group
    (via the CORE_MEMBERSHIPS table, same expansion the oracle uses).
    """
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
    if required_mask and (recipe.tags & required_mask) != required_mask:
        return False
    for row_id, _ in recipe.required:
        if row_id not in available:
            return False
    for row_id, _ in recipe.optional:
        if row_id in excluded:
            return False
    for row_id, _ in recipe.required:
        if row_id in excluded:
            return False
    return True


def check_membership_sync(memberships_path: Path) -> None:
    snapshot = json.loads(
        (memberships_path.parent.parent.parent / "runs" / "catalog_snapshot.json")
        .read_text(encoding="utf-8"))
    ingredient_names = {
        int(k): v for k, v in snapshot["ingredient_names"].items()}
    exported = json.loads(memberships_path.read_text(encoding="utf-8"))
    swift = {row["ingredient_id"]: (row["bundled_name"], set(row["groups"]))
             for row in exported}
    mismatch = []
    for ingredient_id, groups in CORE_MEMBERSHIPS.items():
        if ingredient_id not in swift:
            mismatch.append(f"ingredient {ingredient_id} missing from Swift export")
            continue
        swift_name, swift_groups = swift[ingredient_id]
        if swift_name != ingredient_names.get(ingredient_id):
            mismatch.append(
                f"ingredient {ingredient_id}: name {swift_name!r} != "
                f"{ingredient_names.get(ingredient_id)!r}")
        if swift_groups != groups:
            mismatch.append(
                f"ingredient {ingredient_id}: groups {sorted(swift_groups)} "
                f"!= {sorted(groups)}")
    extra = set(swift) - set(CORE_MEMBERSHIPS)
    if extra:
        mismatch.append(f"Swift export has extra ingredients: {sorted(extra)}")
    if mismatch:
        raise AssertionError("membership table drift:\n  " + "\n  ".join(mismatch[:10]))
    print(f"membership sync: {len(CORE_MEMBERSHIPS)} rows identical between "
          "vendored Swift table and oracle.py")


def check_replay(tool_dir: Path, results_path: Path) -> dict:
    catalog = Catalog.load(tool_dir / "runs" / "catalog_snapshot.json")
    oracle = FeasibilityOracle(catalog)
    states = {}
    with open(tool_dir / "runs" / "states.jsonl", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                state = json.loads(line)
                states[state["state_id"]] = state

    checked = 0
    oracle_disagreements = []
    production_disagreements = []
    counterexamples = 0

    with open(results_path, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            row = json.loads(line)
            checked += 1
            state = states[row["state_id"]]
            recipe = catalog.recipes[row["recipe_id"]]

            expected = oracle.evaluate_recipe(state, recipe)
            if (row["oracle_feasible"] != expected.feasible
                    or set(row["oracle_infeasible_reasons"])
                    != set(expected.infeasible_reasons)
                    or set(row["oracle_missing_required_ids"])
                    != set(expected.missing_required_ids)
                    or set(row["oracle_excluded_ids"]) != set(expected.excluded_ids)
                    or row["oracle_tag_violation"] != expected.tag_violation
                    or set(row["oracle_unknown_quantity_assumptions"])
                    != set(expected.unknown_quantity_assumptions)):
                oracle_disagreements.append(row)

            if row["production_makeable"] != production_verdict(state, recipe):
                production_disagreements.append(row)

            if (row["family"] == "planted_false_complete"
                    and row["production_makeable"]
                    and not row["oracle_feasible"]
                    and set(row["oracle_infeasible_reasons"])
                    == {"insufficient_known_quantity"}):
                counterexamples += 1

    if oracle_disagreements:
        sample = oracle_disagreements[0]
        raise AssertionError(
            f"oracle disagreement on {len(oracle_disagreements)}/{checked} rows; "
            f"first: state {sample['state_id']} recipe {sample['recipe_id']}")
    if production_disagreements:
        sample = production_disagreements[0]
        raise AssertionError(
            f"production-arm disagreement on {len(production_disagreements)} rows; "
            f"first: state {sample['state_id']} recipe {sample['recipe_id']}")

    print(f"replay cross-check: {checked} rows, oracle and production arms "
          "identical across Python and Swift")
    print(f"planted false-complete confirmed in replay: {counterexamples} "
          "(state, recipe) pairs where production claims makeable and the data "
          "model refutes it")
    return {
        "rows_checked": checked,
        "oracle_disagreements": 0,
        "production_disagreements": 0,
        "planted_false_complete_confirmed": counterexamples,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool-dir", type=Path,
                        default=Path(__file__).resolve().parent)
    parser.add_argument("--results", type=Path, default=None)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()

    memberships = args.tool_dir / "swift" / ".build" / "memberships_export.json"
    results = args.results

    if not args.skip_build:
        swift_dir = args.tool_dir / "swift"
        subprocess.run(["swift", "build"], cwd=swift_dir, check=True,
                       capture_output=True)
        out = subprocess.run(
            [str(swift_dir / ".build" / "debug" / "PantryFeasibilityReplay"),
             "export-memberships"],
            cwd=swift_dir, check=True, capture_output=True, text=True).stdout
        memberships.write_text(out, encoding="utf-8")
        if results is None:
            out_path = args.tool_dir / "swift" / ".build" / "replay_results.jsonl"
            subprocess.run(
                [str(swift_dir / ".build" / "debug" / "PantryFeasibilityReplay"),
                 "replay", "--corpus-dir", str(args.tool_dir / "runs"),
                 "--output", str(out_path)],
                cwd=swift_dir, check=True)
            results = out_path

    check_membership_sync(memberships)
    summary = check_replay(args.tool_dir, results)
    (args.tool_dir / "runs" / "replay_verification.json").write_text(
        json.dumps(summary, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
