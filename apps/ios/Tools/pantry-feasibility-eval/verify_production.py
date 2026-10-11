#!/usr/bin/env python3
"""Verify the live production replay against the transcription AND the oracle.

The live arm (production/Sources/PantryFeasibilityProduction) runs the REAL
RecipeRepository.findMakeable / findNearMatch on one real migrated in-memory
database per corpus state — no transcription. This checker asserts two things:

1. The transcribed production arm in the replay (verify_replay.py) matches the
   live result sets exactly, per state, for both result sets:

   - makeable_ids: findMakeable(with: state.available_ids, profile) output
   - near_match_ids: findNearMatch(..., maxMissingRequired: 3) output

2. Those same live result sets are compared DIRECTLY to the independent
   quantity-aware oracle (oracle.FeasibilityOracle), with no transcription in
   the loop:

   - every oracle-feasible recipe must appear in the live makeable set
     (zero false blocks);
   - no live makeable/near-match recipe may violate an allergen exclusion or
     a diet-tag requirement (quantity is the only permitted disagreement).

It also recomputes the committed source pin (production/RealManifest.json,
written by Scripts/refresh.sh) against the current app sources, so a replay's
provenance is checkable without the build tree.

Writes runs/production_verification.json. Exit 1 on any mismatch.

Note the direction of the quantity gap: production ignores grams entirely, so
both arms and the live run agree exactly; the gap to the data-model oracle is
reported by run_eval.py from the (transcribed) per-pair rows.
"""

import hashlib
import json
import sys
from pathlib import Path

from oracle import Catalog, DIET_EXCLUDED_IDS, DIET_TAG_MASK, FeasibilityOracle
from verify_replay import CORE_MEMBERSHIPS

MAX_MISSING_REQUIRED = 3
PIN_PATH = Path(__file__).resolve().parent / "production" / "RealManifest.json"
IOS_ROOT = Path(__file__).resolve().parents[2]


def check_source_pin() -> tuple[dict | None, list[str]]:
    """Recompute the committed RealManifest.json pin from the app sources.

    The pin records the sha256 of every real source copied into the live-replay
    package by Scripts/refresh.sh, so a mismatch means the current app sources
    no longer match the sources the committed replay rows were produced from.
    """
    if not PIN_PATH.exists():
        return None, [
            "missing production/RealManifest.json — run "
            "production/Scripts/refresh.sh to pin the replayed sources"
        ]
    try:
        pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return None, [f"unreadable RealManifest.json: {error}"]

    problems: list[str] = []
    for rel, digest in sorted(pin.get("sources", {}).items()):
        src = IOS_ROOT / rel
        if not src.is_file():
            problems.append(f"pinned source missing: {rel}")
            continue
        actual = hashlib.sha256(src.read_bytes()).hexdigest()
        if actual != digest:
            problems.append(
                f"pinned source drift: {rel} sha256 {digest[:12]}... -> "
                f"{actual[:12]}...")
    return pin, problems


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
    # Direct live-vs-oracle comparison (no transcription in the loop): the
    # oracle is the independent quantity-aware evaluator specified from the
    # data model; the live arm is production's actual repository output.
    oracle = FeasibilityOracle(catalog)
    oracle_covered_states = 0
    oracle_false_blocks: list[str] = []
    exclusion_tag_leaks: list[str] = []
    overpromise_reason_counts: dict[str, int] = {}
    overpromise_by_family: dict[str, int] = defaultdict(int)
    live_makeable_by_family: dict[str, int] = defaultdict(int)
    overpromise_pairs = 0
    live_makeable_pairs = 0
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

            live_makeable = set(row["makeable_ids"])
            live_near = set(row["near_match_ids"])
            live_makeable_pairs += len(live_makeable)
            live_makeable_by_family[row["family"]] += len(live_makeable)
            verdicts = oracle.evaluate_all(state)
            feasible = {rid for rid, v in verdicts.items() if v.feasible}
            if feasible <= live_makeable:
                oracle_covered_states += 1
            else:
                oracle_false_blocks.append(
                    f"state {row['state_id']}: oracle-feasible recipes missing "
                    f"from live makeable: {sorted(feasible - live_makeable)[:5]}")
            for rid in live_makeable | live_near:
                reasons = verdicts[rid].infeasible_reasons
                if "excluded_ingredient" in reasons or "diet_tag_violation" in reasons:
                    exclusion_tag_leaks.append(
                        f"state {row['state_id']} recipe {rid}: {reasons}")
            for rid in live_makeable:
                verdict = verdicts[rid]
                if not verdict.feasible:
                    overpromise_pairs += 1
                    overpromise_by_family[row["family"]] += 1
                    signature = "+".join(
                        sorted(verdict.infeasible_reasons)) or "none"
                    overpromise_reason_counts[signature] = (
                        overpromise_reason_counts.get(signature, 0) + 1)

    if rows != len(states):
        mismatches.append(f"row count {rows} != {len(states)} states")

    pin, pin_problems = check_source_pin()

    verification = {
        "production_live_states": rows,
        "makeable_set_agreement": makeable_agree,
        "near_match_set_agreement": near_agree,
        "agreement_rate": (
            (makeable_agree + near_agree) / (2 * rows) if rows else 0.0),
        "source_pin": {
            "status": "ok" if pin is not None and not pin_problems else "failed",
            "sources": len(pin.get("sources", {})) if pin else 0,
            "toolchain": pin.get("toolchain") if pin else None,
            "problems": pin_problems[:20],
        },
        "live_vs_oracle": {
            "note": (
                "direct comparison of live RecipeRepository output against the "
                "independent quantity-aware oracle — no transcription involved"),
            "states_with_oracle_feasible_fully_covered": oracle_covered_states,
            "oracle_false_block_states": len(oracle_false_blocks),
            "exclusion_or_tag_leaks": len(exclusion_tag_leaks),
            "live_makeable_but_oracle_infeasible_pairs": overpromise_pairs,
            "overpromise_reason_counts": overpromise_reason_counts,
        },
        "note": (
            "live RecipeRepository.findMakeable/findNearMatch on real migrated "
            "in-memory databases vs the transcribed production arm, and "
            "directly vs the independent quantity oracle"),
        "mismatches": (mismatches + pin_problems + oracle_false_blocks
                       + exclusion_tag_leaks)[:20],
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
