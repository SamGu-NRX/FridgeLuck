"""Hand-computed exact ambiguity witnesses.

Every number in this module is hand-computed and asserted, then bound to the
bundled recipe metadata (apps/ios/Resources/data.json). If the bundle drifts,
the assertions fail — the witnesses stay source-bound.

The witness set covers the three ambiguity sources the study declares:

1. identical available evidence, different serving allocations
   (a doubled cook hides a serving);
2. unknown recipe identity (different recipes render the same plate);
3. invalid denominators (declared servings <= 0 / non-integer; portion
   multiplier <= 0 or non-finite; plate weight <= 0).

plus the two constructive counterparts:

4. the portion/reference trade-off (an explicit per-serving reference weight
   still leaves servings ambiguous against the confirmed portion);
5. confirmation that resolves it (portion confirmed -> target unique).
"""

from __future__ import annotations

from fractions import Fraction as F

import bundled
import schema

# Hand-copied from apps/ios/Resources/data.json (recipe id -> title,
# declared servings, required-ingredient grams):
KORMA_ID = 50  # "Chicken korma", servings 2, required batch 260 g
CURRY_ID = 45  # "Chetna's end-of-summer veg curry", servings 2, batch 528 g
COUSCOUS_ID = 107  # "One-pot garlicky chicken thighs & giant cous cous", servings 2, batch 88 g


def _bundled(recipe_id: int) -> dict:
    for r in bundled.load_bundled_recipes():
        if r["recipe_id"] == recipe_id:
            return r
    raise AssertionError(f"bundled recipe {recipe_id} not found")


def _check_bundle_binding() -> None:
    """The hand-copied numbers must still match the bundle."""
    korma, curry, couscous = _bundled(KORMA_ID), _bundled(CURRY_ID), _bundled(COUSCOUS_ID)
    assert korma["title"] == "Chicken korma" and korma["declared_servings"] == 2
    assert korma["required_grams"] == F(260), korma["required_grams"]
    assert curry["title"].startswith("Chetna's end-of-summer veg curry")
    assert curry["declared_servings"] == 2 and curry["required_grams"] == F(528)
    assert couscous["title"].startswith("One-pot garlicky chicken thighs")
    assert couscous["declared_servings"] == 2 and couscous["required_grams"] == F(88)


def witness_same_evidence_different_allocations() -> dict:
    """Evidence {plate 260 g, recipe korma, declared servings 2}:
    world A ate 1 serving of a double cook; world B ate 2 servings of a
    single cook. Same evidence, targets {1, 2}.

    Hand check (forward model batch x consumed x portion / declared):
      A: 520 x 1 x 1 / 2 = 260   B: 260 x 2 x 1 / 2 = 260
    """
    _check_bundle_binding()
    world_a = schema.make_world(
        recipe_id=KORMA_ID,
        title="Chicken korma",
        declared_servings=2,
        batch_grams=F(520),  # doubled cook of the 260 g declared batch
        consumed_servings=1,
        portion_multiplier=F(1),
    )
    world_b = schema.make_world(
        recipe_id=KORMA_ID,
        title="Chicken korma",
        declared_servings=2,
        batch_grams=F(260),
        consumed_servings=2,
        portion_multiplier=F(1),
    )
    ev_a = schema.evidence_from_world(world_a, reveal_identity=True, reveal_declared=True)
    ev_b = schema.evidence_from_world(world_b, reveal_identity=True, reveal_declared=True)
    assert ev_a == ev_b, "the two worlds must render identical evidence"
    assert schema.observed_plate_grams(world_a) == F(260)
    assert schema.observed_plate_grams(world_b) == F(260)
    return {
        "name": "same_evidence_different_allocations",
        "evidence": ev_a,
        "worlds": (world_a, world_b),
        "targets": (1, 2),
        "arithmetic": ["520 x 1 x 1 / 2 = 260 (target 1)", "260 x 2 x 1 / 2 = 260 (target 2)"],
    }


def witness_unknown_recipe_identity() -> dict:
    """Evidence {plate reads 265 g}, recipe unknown:
    world A is 1 serving of a 528 g curry cook; world B is 3 servings (double
    portion) of an 88 g cous cous cook. Both cook batches render exactly
    264 g, and at the 5 g kitchen-scale resolution both plates read 265 g
    (264 / 5 = 52.8 -> 53 x 5). Same evidence, targets {1, 3}.

    Hand check:
      A: 528 x 1 x 1 / 2 = 264   B: 88 x 3 x 2 / 2 = 264  (both read 265 g)
    """
    _check_bundle_binding()
    world_a = schema.make_world(
        recipe_id=CURRY_ID,
        title="Chetna's end-of-summer veg curry",
        declared_servings=2,
        batch_grams=F(528),
        consumed_servings=1,
        portion_multiplier=F(1),
    )
    world_b = schema.make_world(
        recipe_id=COUSCOUS_ID,
        title="One-pot garlicky chicken thighs & giant cous cous",
        declared_servings=2,
        batch_grams=F(88),
        consumed_servings=3,
        portion_multiplier=F(2),
    )
    ev_a = schema.evidence_from_world(world_a)
    ev_b = schema.evidence_from_world(world_b)
    assert ev_a == ev_b, "the two worlds must render identical evidence"
    assert schema.rendered_plate_grams(world_a) == F(264) == schema.rendered_plate_grams(world_b)
    assert ev_a.plate_weight_g == F(265)  # 264 g at 5 g resolution reads 265 g
    assert ev_a.recipe_identity is None and ev_a.declared_servings is None
    return {
        "name": "unknown_recipe_identity",
        "evidence": ev_a,
        "worlds": (world_a, world_b),
        "targets": (1, 3),
        "arithmetic": [
            "528 x 1 x 1 / 2 = 264 (target 1)",
            "88 x 3 x 2 / 2 = 264 (target 3)",
            "both plates read 265 g at the 5 g scale resolution",
        ],
    }


def witness_portion_reference_tradeoff() -> dict:
    """Evidence {plate 260 g, recipe korma, declared 2, reference 130 g/serving}:
    the reference pins the realized batch (260 g this cook) but not the
    portion. World A ate 2 servings at portion 1.0; world B ate 1 serving at
    portion 2.0. Same evidence, targets {2, 1}.

    Hand check:
      A: 260 x 2 x 1 / 2 = 260, per-serving 260/2 = 130
      B: 260 x 1 x 2 / 2 = 260, per-serving 260/2 = 130
    """
    _check_bundle_binding()
    world_a = schema.make_world(
        recipe_id=KORMA_ID,
        title="Chicken korma",
        declared_servings=2,
        batch_grams=F(260),
        consumed_servings=2,
        portion_multiplier=F(1),
    )
    world_b = schema.make_world(
        recipe_id=KORMA_ID,
        title="Chicken korma",
        declared_servings=2,
        batch_grams=F(260),
        consumed_servings=1,
        portion_multiplier=F(2),
    )
    ev_a = schema.evidence_from_world(
        world_a, reveal_identity=True, reveal_declared=True, reveal_reference=True
    )
    ev_b = schema.evidence_from_world(
        world_b, reveal_identity=True, reveal_declared=True, reveal_reference=True
    )
    assert ev_a == ev_b, "the two worlds must render identical evidence"
    assert ev_a.reference_weight_g == F(130)
    assert ev_a.plate_weight_g == F(260) and ev_a.portion_multiplier is None
    return {
        "name": "portion_reference_tradeoff",
        "evidence": ev_a,
        "worlds": (world_a, world_b),
        "targets": (2, 1),
        "arithmetic": [
            "260 x 2 x 1 / 2 = 260 (target 2, portion 1.0)",
            "260 x 1 x 2 / 2 = 260 (target 1, portion 2.0)",
        ],
    }


def witness_resolved_by_portion_confirmation() -> dict:
    """The trade-off worlds plus a confirmed portion 1.0: only the 2-serving
    world remains consistent, so the target is identifiable (= 2).

    Hand check: with plate 260 g, reference 130 g, portion 1.0, the forward
    model forces consumed x portion = 260/130 = 2, i.e. consumed = 2.
    """
    base = witness_portion_reference_tradeoff()
    ev = schema.evidence_from_world(
        base["worlds"][0],
        reveal_identity=True,
        reveal_declared=True,
        reveal_reference=True,
        reveal_multiplier=True,
    )
    result = schema.classify((base["worlds"][0], base["worlds"][1]), ev)
    assert result.identifiable and result.targets == (2,)
    return {
        "name": "resolved_by_portion_confirmation",
        "evidence": ev,
        "worlds": base["worlds"],
        "targets": (2,),
        "arithmetic": ["260 / (130 x 1.0) = 2 -> the only consistent target is 2"],
    }


def invalid_observation_cases() -> list[dict]:
    """Invalid denominators and observations, each bound to its source rule."""
    return [
        {
            "case": "declared_servings = 0",
            "source_rule": "InventoryRepository.servingFactor clamps max(recipeServings, 1); study refuses",
            "expect": schema.DenominatorInvalid,
            "call": lambda: schema.make_evidence(
                plate_weight_g=F(260), recipe_identity=KORMA_ID, declared_servings=0
            ),
        },
        {
            "case": "declared_servings = -2",
            "source_rule": "same clamp; study refuses negative denominators",
            "expect": schema.DenominatorInvalid,
            "call": lambda: schema.make_evidence(
                plate_weight_g=F(260), recipe_identity=KORMA_ID, declared_servings=-2
            ),
        },
        {
            "case": "declared_servings = 2.5",
            "source_rule": "Recipe.servings is Int; a non-integer denominator cannot be a serving count",
            "expect": schema.DenominatorInvalid,
            "call": lambda: schema.make_evidence(
                plate_weight_g=F(260), recipe_identity=KORMA_ID, declared_servings=2.5
            ),
        },
        {
            "case": "portion_multiplier = 0",
            "source_rule": "MealLogError.invalidPortionMultiplier (must be positive)",
            "expect": schema.InvalidPortionMultiplier,
            "call": lambda: schema.make_evidence(plate_weight_g=F(260), portion_multiplier=0),
        },
        {
            "case": "portion_multiplier = -1.5",
            "source_rule": "MealLogError.invalidPortionMultiplier (must be positive)",
            "expect": schema.InvalidPortionMultiplier,
            "call": lambda: schema.make_evidence(
                plate_weight_g=F(260), portion_multiplier=F(-3, 2)
            ),
        },
        {
            "case": "portion_multiplier = NaN",
            "source_rule": "MealLogService guard portionMultiplier.isFinite",
            "expect": schema.InvalidPortionMultiplier,
            "call": lambda: schema.make_evidence(
                plate_weight_g=F(260), portion_multiplier=float("nan")
            ),
        },
        {
            "case": "portion_multiplier = +inf",
            "source_rule": "MealLogService guard portionMultiplier.isFinite",
            "expect": schema.InvalidPortionMultiplier,
            "call": lambda: schema.make_evidence(
                plate_weight_g=F(260), portion_multiplier=float("inf")
            ),
        },
        {
            "case": "plate_weight_g = 0",
            "source_rule": "no scale input exists in the app source; the study requires a positive plate weight",
            "expect": schema.InvalidPlateWeight,
            "call": lambda: schema.make_evidence(plate_weight_g=0),
        },
        {
            "case": "plate_weight_g = -100",
            "source_rule": "no scale input exists in the app source; the study requires a positive plate weight",
            "expect": schema.InvalidPlateWeight,
            "call": lambda: schema.make_evidence(plate_weight_g=F(-100)),
        },
        {
            "case": "plate_weight_g = NaN",
            "source_rule": "plate weight must be a finite measurement",
            "expect": schema.InvalidPlateWeight,
            "call": lambda: schema.make_evidence(plate_weight_g=float("nan")),
        },
        {
            "case": "world declared_servings = 0",
            "source_rule": "a world with a zero denominator is not constructible",
            "expect": schema.DenominatorInvalid,
            "call": lambda: schema.make_world(
                recipe_id=KORMA_ID,
                title="Chicken korma",
                declared_servings=0,
                batch_grams=F(260),
                consumed_servings=1,
                portion_multiplier=F(1),
            ),
        },
    ]


def witness_counts() -> dict:
    return {
        "witness_pairs": {
            "same_evidence_different_allocations": 1,
            "unknown_recipe_identity": 1,
            "portion_reference_tradeoff": 1,
            "resolved_by_portion_confirmation": 1,
        },
        "invalid_observation_cases": len(invalid_observation_cases()),
        "note": (
            "hand-computed pairs; every number is asserted against the bundled "
            "recipe metadata before the witness is returned"
        ),
    }


ALL_WITNESS_BUILDERS = (
    witness_same_evidence_different_allocations,
    witness_unknown_recipe_identity,
    witness_portion_reference_tradeoff,
    witness_resolved_by_portion_confirmation,
)
