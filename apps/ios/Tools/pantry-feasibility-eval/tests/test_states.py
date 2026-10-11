"""Frozen-corpus tests: shape, coverage, and planted counterexamples.

These run against the frozen runs/ directory. Regenerate with
`python3 generate_states.py` if states.jsonl is missing.
"""

import json
from pathlib import Path

import pytest
from oracle import Catalog, FeasibilityOracle

TOOL_DIR = Path(__file__).resolve().parents[1]
RUNS_DIR = TOOL_DIR / "runs"

MIN_STATES = 5000
SUPPORTED_DIETS = {"none", "vegan", "vegetarian", "pescatarian", "keto"}
GROUP_IDS = {
    "milk", "egg", "peanut", "tree_nut", "wheat_gluten",
    "soy", "fish", "shellfish", "sesame", "mustard",
}


@pytest.fixture(scope="module")
def catalog():
    return Catalog.load(RUNS_DIR / "catalog_snapshot.json")


@pytest.fixture(scope="module")
def oracle(catalog):
    return FeasibilityOracle(catalog)


@pytest.fixture(scope="module")
def states():
    rows = []
    with open(RUNS_DIR / "states.jsonl", "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


@pytest.fixture(scope="module")
def manifest():
    return json.loads((RUNS_DIR / "manifest.json").read_text(encoding="utf-8"))


def test_corpus_size(states):
    assert len(states) >= MIN_STATES


def test_manifest_hashes_match_files(manifest):
    import hashlib

    def sha(path):
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()

    assert sha(RUNS_DIR / "states.jsonl") == manifest["states_sha256"]
    assert sha(RUNS_DIR / "catalog_snapshot.json") == manifest["catalog_snapshot_sha256"]


def test_state_ids_unique_and_sorted(states):
    ids = [s["state_id"] for s in states]
    assert ids == sorted(ids)
    assert len(set(ids)) == len(ids)


def test_available_ids_consistent_with_pantry(states, oracle):
    for state in states:
        assert set(state["available_ids"]) == oracle.available_ids(state), (
            f"state {state['state_id']}"
        )


def test_constraint_coverage(states, manifest):
    coverage = manifest["coverage"]
    assert coverage["states_with_empty_pantry"] > 0
    assert coverage["states_with_empty_available_set"] > 0
    assert coverage["states_with_unknown_quantity_lots"] > 0
    assert coverage["states_with_zero_remaining_lots"] > 0
    assert coverage["states_with_known_quantity_lots"] > 0
    assert set(coverage["diets"]) == SUPPORTED_DIETS
    assert coverage["profiles_version_0"] > 0
    assert coverage["profiles_version_1"] > 0


def test_all_canonical_allergen_groups_selected_somewhere(states):
    seen = set()
    for state in states:
        groups = state["profile"]["allergen_groups"]
        if all(g in GROUP_IDS for g in groups):
            seen.update(groups)
    assert seen == GROUP_IDS


def test_noncanonical_group_strings_planted(states):
    hits = [s for s in states
            if any(g not in GROUP_IDS for g in s["profile"]["allergen_groups"])]
    assert hits, "no state plants a non-canonical allergen group string"
    oracle = FeasibilityOracle(Catalog.load(RUNS_DIR / "catalog_snapshot.json"))
    for state in hits[:20]:
        # production drops unknown group strings; so must the oracle
        assert oracle.effective_exclusions(state["profile"]) == set(
            oracle.effective_exclusions({**state["profile"],
                                         "allergen_groups": []}))


def test_planted_false_complete_counterexamples(states, oracle, catalog):
    """Every planted state must yield at least one recipe that is fully
    covered by pantry IDs (production would claim it complete) yet infeasible
    by the data model purely because of a known short quantity."""
    checked = 0
    for state in states:
        if state["family"] != "planted_false_complete":
            continue
        checked += 1
        pantry_ids = {e["ingredient_id"] for e in state["pantry"]}
        covered = [rid for rid, recipe in catalog.recipes.items()
                   if set(i for i, _ in recipe.required) <= pantry_ids]
        assert covered, f"state {state['state_id']}: no ID-covered recipe"
        found = False
        for rid in covered:
            verdict = oracle.evaluate_recipe(state, catalog.recipes[rid])
            if (not verdict.feasible
                    and set(verdict.infeasible_reasons) == {"insufficient_known_quantity"}
                    and not verdict.unknown_quantity_assumptions):
                found = True
                break
        assert found, f"state {state['state_id']}: false-complete not isolated"
    assert checked >= 300


def test_agreement_probes_are_feasible_for_oracle(states, oracle, catalog):
    """Probe pantries must leave at least one recipe the oracle calls feasible
    (so the recall denominator is non-trivial on those states)."""
    for state in states:
        if state["family"] != "agreement_probe":
            continue
        pantry_ids = {e["ingredient_id"] for e in state["pantry"]}
        feasible = [
            rid for rid, recipe in catalog.recipes.items()
            if set(i for i, _ in recipe.required) <= pantry_ids
            and oracle.evaluate_recipe(state, recipe).feasible
        ]
        assert feasible, f"state {state['state_id']}: no feasible recipe in probe"


def test_unknown_quantities_preserved_as_unknown(states):
    for state in states:
        for entry in state["pantry"]:
            if entry["is_estimate"]:
                assert entry["known_grams"] is None, (
                    f"state {state['state_id']}: invented grams on an estimate lot"
                )


def test_required_and_optional_rows_present_in_catalog(catalog):
    with_required = sum(1 for r in catalog.recipes.values() if r.required)
    with_optional = sum(1 for r in catalog.recipes.values() if r.optional)
    assert with_required == len(catalog.recipes)  # every recipe has required rows
    assert with_optional > 0  # optional rows exist in the bundled catalog
