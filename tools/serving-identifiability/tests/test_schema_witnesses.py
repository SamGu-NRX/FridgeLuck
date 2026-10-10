"""Hand-computed witness and schema tests.

Run from the repo root:  python3 -m pytest tools/serving-identifiability/tests -q
"""

from __future__ import annotations

from fractions import Fraction as F

import pytest

import schema
import witnesses


# --- schema parity with the source forward model ----------------------------


def test_serving_factor_transcribes_source_formula():
    # InventoryRepository.servingFactor:
    #   Double(max(0, servingsConsumed)) * portionMultiplier / Double(max(recipeServings, 1))
    assert schema.serving_factor(2, F(1), 2) == F(1)
    assert schema.serving_factor(1, F(1), 2) == F(1, 2)
    assert schema.serving_factor(3, F(2), 2) == F(3)
    # source clamp: a zero denominator silently becomes 1 in Swift
    assert schema.serving_factor(1, F(1), 0) == F(1)
    # the schema refuses to construct that world/evidence in the first place
    with pytest.raises(schema.DenominatorInvalid):
        schema.make_evidence(plate_weight_g=F(260), declared_servings=0)


def test_rendered_and_observed_plate_grams():
    world = schema.make_world(
        recipe_id=1,
        title="Classic Egg Fried Rice",
        declared_servings=2,
        batch_grams=F(431),  # 100 + 316 + 15 (bundled required grams, recipe id 1)
        consumed_servings=2,
        portion_multiplier=F(1),
    )
    assert schema.rendered_plate_grams(world) == F(431)
    # kitchen scale at 5 g resolution: 431 g reads as 430 g
    assert schema.observed_plate_grams(world) == F(430)
    assert schema.observed_plate_grams(world, F(1)) == F(431)


# --- witness 1: identical evidence, different serving allocations -----------


def test_witness_same_evidence_different_allocations():
    w = witnesses.witness_same_evidence_different_allocations()
    a, b = w["worlds"]
    # hand-computed targets and arithmetic
    assert a.consumed_servings == 1 and b.consumed_servings == 2
    assert a.batch_grams == F(520) and b.batch_grams == F(260)
    assert schema.rendered_plate_grams(a) == F(260) == schema.rendered_plate_grams(b)
    # identical available evidence, different serving allocations
    assert w["targets"] == (1, 2)
    result = schema.classify(
        (a, b),
        schema.evidence_from_world(a, reveal_identity=True, reveal_declared=True),
    )
    assert not result.identifiable
    assert result.witness_pair is not None


# --- witness 2: unknown recipe identity -------------------------------------


def test_witness_unknown_recipe_identity():
    w = witnesses.witness_unknown_recipe_identity()
    a, b = w["worlds"]
    assert a.recipe_id != b.recipe_id  # two different bundled recipes
    assert a.consumed_servings == 1 and b.consumed_servings == 3
    # hand check: 528 x 1 x 1 / 2 = 264; 88 x 3 x 2 / 2 = 264
    assert schema.rendered_plate_grams(a) == F(264) == schema.rendered_plate_grams(b)
    assert w["evidence"].recipe_identity is None
    assert w["targets"] == (1, 3)
    result = schema.classify((a, b), w["evidence"])
    assert not result.identifiable


# --- witness 3/4: reference weight leaves the portion trade-off -------------


def test_witness_portion_reference_tradeoff():
    w = witnesses.witness_portion_reference_tradeoff()
    a, b = w["worlds"]
    assert a.consumed_servings == 2 and a.portion_multiplier == F(1)
    assert b.consumed_servings == 1 and b.portion_multiplier == F(2)
    # reference weight identical: 260 / 2 = 130 g per serving for this cook
    assert schema.evidence_from_world(a, reveal_reference=True).reference_weight_g == F(130)
    result = schema.classify((a, b), w["evidence"])
    assert not result.identifiable
    assert w["targets"] == (2, 1)


def test_witness_resolved_by_portion_confirmation():
    w = witnesses.witness_resolved_by_portion_confirmation()
    assert w["targets"] == (2,)
    # the same two worlds, now with the portion confirmed
    result = schema.classify(w["worlds"], w["evidence"])
    assert result.identifiable


# --- invalid denominators and invalid observations --------------------------


@pytest.mark.parametrize(
    "case",
    witnesses.invalid_observation_cases(),
    ids=lambda c: c["case"],
)
def test_invalid_observation_cases(case):
    with pytest.raises(case["expect"]):
        case["call"]()


def test_invalid_cases_are_documented_against_source_rules():
    cases = witnesses.invalid_observation_cases()
    assert len(cases) == 11
    assert all(c["source_rule"] for c in cases)


# --- leak discipline --------------------------------------------------------


def test_observation_key_never_contains_target():
    world = witnesses.witness_same_evidence_different_allocations()["worlds"][0]
    ev = schema.evidence_from_world(
        world,
        reveal_identity=True,
        reveal_declared=True,
        reveal_reference=True,
        reveal_multiplier=True,
    )
    key = schema.observation_key(ev)
    assert len(key) == len(schema.OBSERVATION_FIELDS)
    assert schema.TARGET_FIELD not in schema.OBSERVATION_FIELDS


def test_find_outcome_leak_flags_a_target_key_and_clears_an_honest_one():
    worlds = witnesses.witness_same_evidence_different_allocations()["worlds"]

    def honest(w):
        return schema.observation_key(
            schema.evidence_from_world(w, reveal_identity=True, reveal_declared=True)
        )

    assert schema.find_outcome_leak(worlds, honest, honest) is None
    # the intentional mutation: append the outcome to the key
    leaked = lambda w: honest(w) + (w.consumed_servings,)  # noqa: E731
    leak = schema.find_outcome_leak(worlds, leaked, honest)
    assert leak is not None
    assert leak["targets"] == [1, 2]


# --- every declared witness builder stays hand-bound ------------------------


def test_all_witness_builders_reproduce_their_hand_numbers():
    for builder in witnesses.ALL_WITNESS_BUILDERS:
        w = builder()
        # targets must be exactly the consumed-servings values of the worlds
        # that stay consistent with the witness evidence (for the resolved
        # witness, one of the two worlds is eliminated by the confirmation)
        consistent = sorted(
            {
                world.consumed_servings
                for world in w["worlds"]
                if schema.world_is_consistent(world, w["evidence"])
            }
        )
        assert sorted(w["targets"]) == consistent
        assert w["arithmetic"]
