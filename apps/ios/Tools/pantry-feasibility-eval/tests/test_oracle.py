"""Oracle unit tests: feasibility semantics specified from the data model."""

import pytest
from oracle import CORE_MEMBERSHIPS, Catalog, FeasibilityOracle, RecipeRow


@pytest.fixture(scope="module")
def oracle(frozen_catalog):
    return FeasibilityOracle(frozen_catalog)


def make_state(pantry, diet=None, groups=(), individual=(), version=1):
    return {
        "state_id": 0,
        "family": "test",
        "profile": {
            "diet": diet,
            "allergen_groups": list(groups),
            "allergen_ingredient_ids": list(individual),
            "allergen_preferences_version": version,
            "goal": "general",
        },
        "pantry": pantry,
        "available_ids": sorted({entry["ingredient_id"] for entry in pantry}),
    }


# A tiny standalone catalog keeps these tests independent of data.json.
@pytest.fixture
def tiny_catalog():
    recipes = {
        1: RecipeRow(1, "Pancakes", 10, tags=0,
                     required=((1, 100.0), (2, 50.0)),
                     optional=((3, 10.0),)),
        2: RecipeRow(2, "Salad", 5, tags=0,
                     required=((1, 100.0),),
                     optional=()),
    }
    return Catalog(recipes=recipes, ingredient_names={1: "rice", 2: "egg", 3: "oil"})


def test_sufficient_known_quantity_is_feasible(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 100.0, "is_estimate": False},
        {"ingredient_id": 2, "known_grams": 50.0, "is_estimate": False},
    ])
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert verdict.feasible


def test_exact_boundary_is_feasible(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 100.0, "is_estimate": False},
        {"ingredient_id": 2, "known_grams": 50.0, "is_estimate": False},
    ])
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert verdict.feasible and not verdict.insufficient


def test_short_known_quantity_is_infeasible_with_reason(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 99.9, "is_estimate": False},
        {"ingredient_id": 2, "known_grams": 500.0, "is_estimate": False},
    ])
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert not verdict.feasible
    assert verdict.infeasible_reasons == ["insufficient_known_quantity"]
    assert verdict.insufficient[0]["ingredient_id"] == 1
    assert verdict.insufficient[0]["required_grams"] == 100.0
    assert verdict.insufficient[0]["available_grams"] == 99.9


def test_multiple_lots_sum(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 60.0, "is_estimate": False},
        {"ingredient_id": 1, "known_grams": 40.0, "is_estimate": False},
        {"ingredient_id": 2, "known_grams": 50.0, "is_estimate": False},
    ])
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert verdict.feasible


def test_absent_required_ingredient_is_missing(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 100.0, "is_estimate": False},
    ])
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert not verdict.feasible
    assert verdict.infeasible_reasons == ["missing_required_ingredient"]
    assert verdict.missing_required_ids == [2]


def test_zero_remaining_is_exhausted_not_available(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 0.0, "is_estimate": False},
    ])
    assert oracle.available_ids(state) == set()
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[2])
    assert not verdict.feasible
    # the ID is present in the pantry but exhausted: reported as a known
    # quantity shortfall (available 0g), not a missing ingredient
    assert verdict.missing_required_ids == []
    assert verdict.infeasible_reasons == ["insufficient_known_quantity"]
    assert verdict.insufficient[0]["available_grams"] == 0.0
    assert verdict.insufficient[0]["required_grams"] == 100.0


def test_unknown_quantity_never_refutes_feasibility(oracle, tiny_catalog):
    """Estimated (unknown) lots: presence satisfies the requirement, grams stay unknown."""
    state = make_state([
        {"ingredient_id": 1, "known_grams": None, "is_estimate": True},
        {"ingredient_id": 2, "known_grams": None, "is_estimate": True},
    ])
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert verdict.feasible
    assert verdict.unknown_quantity_assumptions == [1, 2]
    assert verdict.insufficient == []


def test_unknown_plus_short_known_mix(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 10.0, "is_estimate": False},
        {"ingredient_id": 1, "known_grams": None, "is_estimate": True},
        {"ingredient_id": 2, "known_grams": 50.0, "is_estimate": False},
    ])
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    # presence with an unknown amount cannot refute: the true total is unknown,
    # so the requirement is satisfied on an assumption, never refuted
    assert verdict.feasible
    assert verdict.unknown_quantity_assumptions == [1]


def test_excluded_optional_ingredient_blocks(oracle, tiny_catalog):
    """An allergen in an optional row still makes the dish unsafe."""
    state = make_state([
        {"ingredient_id": 1, "known_grams": 100.0, "is_estimate": False},
        {"ingredient_id": 2, "known_grams": 50.0, "is_estimate": False},
        {"ingredient_id": 3, "known_grams": 0.0, "is_estimate": False},  # not needed
    ])
    # exclude ingredient 3 (the optional row) via an individual allergen ID
    state["profile"]["allergen_ingredient_ids"] = [3]
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert not verdict.feasible
    assert verdict.infeasible_reasons == ["excluded_ingredient"]
    assert verdict.excluded_ids == [3]


def test_missing_optional_ingredient_does_not_block(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 100.0, "is_estimate": False},
        {"ingredient_id": 2, "known_grams": 50.0, "is_estimate": False},
    ])
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert verdict.feasible


def test_diet_tag_violation(oracle, tiny_catalog):
    state = make_state([
        {"ingredient_id": 1, "known_grams": 100.0, "is_estimate": False},
        {"ingredient_id": 2, "known_grams": 50.0, "is_estimate": False},
    ], diet="vegan")
    # recipe 1 has tags=0, lacks the vegan bit
    verdict = oracle.evaluate_recipe(state, tiny_catalog.recipes[1])
    assert not verdict.feasible
    assert verdict.infeasible_reasons == ["diet_tag_violation"]


def test_vegan_diet_excludes_dairy_ids(oracle, tiny_catalog):
    excluded = oracle.effective_exclusions({"diet": "vegan", "allergen_groups": [],
                                            "allergen_ingredient_ids": []})
    assert excluded == {12, 13, 14, 32, 50}


def test_allergen_group_members_exclude(oracle, tiny_catalog):
    excluded = oracle.effective_exclusions({"diet": None, "allergen_groups": ["milk"],
                                            "allergen_ingredient_ids": []})
    assert excluded == {12, 13, 14, 32, 50}


def test_individual_allergens_union_groups(oracle, tiny_catalog):
    excluded = oracle.effective_exclusions({"diet": None, "allergen_groups": ["fish"],
                                            "allergen_ingredient_ids": [2]})
    assert excluded == {36, 43, 2}


def test_unknown_group_string_dropped_never_honored(oracle):
    excluded = oracle.effective_exclusions({"diet": None,
                                            "allergen_groups": ["not_a_real_group"],
                                            "allergen_ingredient_ids": []})
    assert excluded == set()


def test_multi_group_membership_soy_sauce(oracle):
    excluded = oracle.effective_exclusions({"diet": None, "allergen_groups": ["soy"],
                                            "allergen_ingredient_ids": []})
    assert 3 in excluded and 23 in excluded  # soy sauce and tofu
    excluded_gluten = oracle.effective_exclusions({"diet": None,
                                                   "allergen_groups": ["wheat_gluten"],
                                                   "allergen_ingredient_ids": []})
    assert 3 in excluded_gluten and 9 in excluded_gluten and 15 in excluded_gluten


def test_membership_table_is_exhaustive_over_core_50():
    assert sorted(CORE_MEMBERSHIPS.keys()) == list(range(1, 51))
