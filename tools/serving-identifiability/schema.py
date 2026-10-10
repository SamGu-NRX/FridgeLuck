"""Explicit observation/target schema for recipe-serving identifiability.

Source-bound to SamGu-NRX/FridgeLuck @ feat/meal-photo-confirmation-v1 (the
commit recorded in census.json). The app's forward model:

    InventoryRepository.servingFactor (apps/ios/Platform/Persistence/Repository/InventoryRepository.swift):

        share of the recipe one log covers
            = Double(max(0, servingsConsumed)) * portionMultiplier
              / Double(max(recipeServings, 1))

    required grams per ingredient = RecipeIngredient.quantityGrams * share

so a log's modeled plate total is

    batch_grams * consumed_servings * portion_multiplier / declared_servings

The study asks the inverse question: an observer holds a weighed plate total.
Which consumed_servings values could have produced it? A target is
IDENTIFIABLE under an evidence set iff every world consistent with the
evidence assigns the same consumed_servings; otherwise the evidence is
ambiguous, and two consistent worlds with different targets form an exact
ambiguity witness.

All arithmetic is exact (fractions.Fraction): no floating-point tolerance
is involved anywhere in the classification.

Roles (full census with file:line bindings in census.json):

    observations   plate_weight_g          weighed plate total (external; the
                                           app source has no scale input)
                   recipe_identity         revealed Recipe.id (None = unknown)
                   declared_servings       revealed Recipe.servings
                   portion_multiplier      user-confirmed portion
                                           (MealLogService.logMeal)
                   reference_weight_g      explicit per-serving weight of this
                                           cook (e.g. a pot-weighed total
                                           divided by declared servings)
                   scale_resolution_g      kitchen-scale readout resolution
    target         consumed_servings       the log's servingsConsumed — the
                                           quantity the plate weight must
                                           identify
    world facts    batch_grams             realized required-ingredient grams
                   declared_servings       the recipe's true declared servings
                   portion_multiplier      the true confirmed portion
"""

from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass
from fractions import Fraction
from typing import Callable, Iterable

TARGET_FIELD = "consumed_servings"

#: Fields of the observation an evidence set may carry. The target is NOT one
#: of them; `find_outcome_leak` exists to enforce exactly that.
OBSERVATION_FIELDS = (
    "plate_weight_g",
    "recipe_identity",
    "declared_servings",
    "portion_multiplier",
    "reference_weight_g",
    "scale_resolution_g",
)

#: Constructed observation model for the family: a kitchen scale read out in
#: 5 g steps. This is a family assumption (documented in README.md), not a
#: claim about any device.
DEFAULT_RESOLUTION = Fraction(5)


class ObservationError(ValueError):
    """An observation violates the schema."""


class InvalidPlateWeight(ObservationError):
    pass


class DenominatorInvalid(ObservationError):
    """declared_servings is not a positive integer.

    The source silently clamps this case (`max(recipeServings, 1)` in
    InventoryRepository.servingFactor); this schema refuses it instead, so a
    broken denominator can never quietly pass for 1 serving.
    """


class InvalidPortionMultiplier(ObservationError):
    """Mirror of MealLogError.invalidPortionMultiplier
    (MealLogService.swift: "Portion multiplier must be a positive number")."""


def as_fraction(value, field: str) -> Fraction:
    if isinstance(value, Fraction):
        return value
    if isinstance(value, bool):
        raise ObservationError(f"{field}: boolean is not a number")
    if isinstance(value, int):
        return Fraction(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ObservationError(f"{field}: must be finite, got {value!r}")
        # The family's grid values (e.g. 0.5, 1.5) are exactly representable
        # in binary floating point; the limit only guards stray inputs.
        return Fraction(value).limit_denominator(10**9)
    raise ObservationError(f"{field}: expected a number, got {type(value).__name__}")


@dataclass(frozen=True)
class World:
    """A fully constructed cooking world. Every fact is exact."""

    recipe_id: int
    title: str
    declared_servings: int  # Recipe.servings
    batch_grams: Fraction  # realized required-ingredient grams (declared sum x cook scale)
    consumed_servings: int  # TARGET — the log's servingsConsumed
    portion_multiplier: Fraction

    @property
    def realized_per_serving_g(self) -> Fraction:
        """Per-serving weight of this cook (batch as cooked / declared servings)."""
        return self.batch_grams / Fraction(self.declared_servings)


def make_world(
    *,
    recipe_id: int,
    title: str,
    declared_servings,
    batch_grams,
    consumed_servings,
    portion_multiplier,
) -> World:
    if isinstance(declared_servings, bool) or not isinstance(declared_servings, int):
        raise DenominatorInvalid(
            f"declared_servings must be a positive integer, got {declared_servings!r}"
        )
    if declared_servings < 1:
        raise DenominatorInvalid(
            f"declared_servings must be >= 1, got {declared_servings} "
            "(source clamps max(recipeServings, 1); the study refuses)"
        )
    if isinstance(consumed_servings, bool) or not isinstance(consumed_servings, int):
        raise ObservationError(
            f"consumed_servings must be a positive integer, got {consumed_servings!r}"
        )
    if consumed_servings < 1:
        raise ObservationError(
            f"consumed_servings must be >= 1 (source logs max(1, servingsConsumed)), "
            f"got {consumed_servings}"
        )
    if isinstance(portion_multiplier, float) and not math.isfinite(portion_multiplier):
        # MealLogService.swift: guard portionMultiplier.isFinite, portionMultiplier > 0
        raise InvalidPortionMultiplier(
            f"portion_multiplier must be finite, got {portion_multiplier!r}"
        )
    mult = as_fraction(portion_multiplier, "portion_multiplier")
    if mult <= 0:
        # MealLogService.swift: guard portionMultiplier.isFinite, portionMultiplier > 0
        raise InvalidPortionMultiplier(
            f"portion_multiplier must be positive, got {portion_multiplier!r}"
        )
    batch = as_fraction(batch_grams, "batch_grams")
    if batch <= 0:
        raise ObservationError(f"batch_grams must be positive, got {batch_grams!r}")
    return World(
        recipe_id=int(recipe_id),
        title=str(title),
        declared_servings=declared_servings,
        batch_grams=batch,
        consumed_servings=consumed_servings,
        portion_multiplier=mult,
    )


@dataclass(frozen=True)
class Evidence:
    """What the observer holds. `None` means the field is absent/unknown."""

    plate_weight_g: Fraction
    recipe_identity: int | None
    declared_servings: int | None
    portion_multiplier: Fraction | None
    reference_weight_g: Fraction | None
    scale_resolution_g: Fraction


def make_evidence(
    *,
    plate_weight_g,
    recipe_identity=None,
    declared_servings=None,
    portion_multiplier=None,
    reference_weight_g=None,
    scale_resolution_g=DEFAULT_RESOLUTION,
) -> Evidence:
    if isinstance(plate_weight_g, float) and not math.isfinite(plate_weight_g):
        raise InvalidPlateWeight(f"plate_weight_g must be finite, got {plate_weight_g!r}")
    plate = as_fraction(plate_weight_g, "plate_weight_g")
    if plate <= 0:
        raise InvalidPlateWeight(f"plate_weight_g must be positive, got {plate_weight_g!r}")
    if recipe_identity is not None:
        if isinstance(recipe_identity, bool) or not isinstance(recipe_identity, int):
            raise ObservationError(
                f"recipe_identity must be an integer recipe id or None, got {recipe_identity!r}"
            )
        if recipe_identity < 1:
            raise ObservationError(f"recipe_identity must be >= 1, got {recipe_identity}")
    if declared_servings is not None:
        if isinstance(declared_servings, bool) or not isinstance(declared_servings, int):
            raise DenominatorInvalid(
                f"declared_servings must be a positive integer, got {declared_servings!r}"
            )
        if declared_servings < 1:
            raise DenominatorInvalid(
                f"declared_servings must be >= 1, got {declared_servings} "
                "(source clamps max(recipeServings, 1); the study refuses)"
            )
    mult = None
    if portion_multiplier is not None:
        if isinstance(portion_multiplier, float) and not math.isfinite(portion_multiplier):
            raise InvalidPortionMultiplier(
                f"portion_multiplier must be finite, got {portion_multiplier!r}"
            )
        mult = as_fraction(portion_multiplier, "portion_multiplier")
        if mult <= 0:
            raise InvalidPortionMultiplier(
                f"portion_multiplier must be positive, got {portion_multiplier!r}"
            )
    ref = None
    if reference_weight_g is not None:
        ref = as_fraction(reference_weight_g, "reference_weight_g")
        if ref <= 0:
            raise ObservationError(
                f"reference_weight_g must be positive, got {reference_weight_g!r}"
            )
    res = as_fraction(scale_resolution_g, "scale_resolution_g")
    if res <= 0:
        raise ObservationError(
            f"scale_resolution_g must be positive, got {scale_resolution_g!r}"
        )
    return Evidence(
        plate_weight_g=plate,
        recipe_identity=recipe_identity,
        declared_servings=declared_servings,
        portion_multiplier=mult,
        reference_weight_g=ref,
        scale_resolution_g=res,
    )


def serving_factor(
    consumed_servings: int, portion_multiplier, declared_servings: int
) -> Fraction:
    """Exact transcription of InventoryRepository.servingFactor, including the
    source's max(recipeServings, 1) clamp. Schema-level construction rejects a
    non-positive declared_servings before this is ever called; the clamp is
    kept so this function is literally the source formula.
    """
    return Fraction(max(0, int(consumed_servings))) * Fraction(portion_multiplier) / Fraction(
        max(int(declared_servings), 1)
    )


def rendered_plate_grams(world: World) -> Fraction:
    """Modeled plate total the world produces (required ingredients only, the
    scaling consumptionRequests and MealBreakdownContent.make use)."""
    return world.batch_grams * serving_factor(
        world.consumed_servings, world.portion_multiplier, world.declared_servings
    )


def observed_plate_grams(world: World, scale_resolution_g=DEFAULT_RESOLUTION) -> Fraction:
    """Kitchen-scale readout: nearest step, ties up, exact Fraction arithmetic."""
    res = as_fraction(scale_resolution_g, "scale_resolution_g")
    value = rendered_plate_grams(world) / res
    floor = value.numerator // value.denominator
    step = floor + (1 if value - floor >= Fraction(1, 2) else 0)
    return Fraction(step) * res


def evidence_from_world(
    world: World,
    *,
    reveal_identity: bool = False,
    reveal_declared: bool = False,
    reveal_reference: bool = False,
    reveal_multiplier: bool = False,
    scale_resolution_g=DEFAULT_RESOLUTION,
) -> Evidence:
    """Render the observation an evidence arm would hold for this world.

    Revealed values are measurable or metadata-bound facts only: the plate
    weight (the scale readout), bundle metadata behind identity/declared
    servings, the pot-weighed per-serving reference, and the user's confirmed
    portion. The target is never consulted.
    """
    return make_evidence(
        plate_weight_g=observed_plate_grams(world, scale_resolution_g),
        recipe_identity=world.recipe_id if reveal_identity else None,
        declared_servings=world.declared_servings if reveal_declared else None,
        reference_weight_g=world.realized_per_serving_g if reveal_reference else None,
        portion_multiplier=world.portion_multiplier if reveal_multiplier else None,
        scale_resolution_g=scale_resolution_g,
    )


def observation_key(ev: Evidence) -> tuple:
    """The observation-only grouping key. No target field may enter here."""
    return tuple(getattr(ev, field) for field in OBSERVATION_FIELDS)


def world_is_consistent(world: World, ev: Evidence) -> bool:
    """Could this world have produced this evidence?"""
    if ev.recipe_identity is not None and world.recipe_id != ev.recipe_identity:
        return False
    if ev.declared_servings is not None and world.declared_servings != ev.declared_servings:
        return False
    if ev.portion_multiplier is not None and world.portion_multiplier != ev.portion_multiplier:
        return False
    if (
        ev.reference_weight_g is not None
        and world.realized_per_serving_g != ev.reference_weight_g
    ):
        return False
    return observed_plate_grams(world, ev.scale_resolution_g) == ev.plate_weight_g


@dataclass(frozen=True)
class ClassResult:
    """One equivalence class: worlds sharing one observation."""

    key: tuple
    evidence: Evidence
    worlds: tuple
    targets: tuple  # sorted distinct consumed_servings values

    @property
    def identifiable(self) -> bool:
        return len(self.targets) == 1

    @property
    def witness_pair(self) -> tuple[World, World] | None:
        """First pair of consistent worlds with different targets, else None."""
        if len(self.targets) <= 1:
            return None
        first_by_target: dict[int, World] = {}
        for w in self.worlds:
            first_by_target.setdefault(w.consumed_servings, w)
            if len(first_by_target) > 1:
                return (first_by_target[self.targets[0]], w)
        return None


def classify(worlds: Iterable[World], ev: Evidence) -> ClassResult:
    """All worlds consistent with `ev`, and whether they agree on the target."""
    consistent = tuple(w for w in worlds if world_is_consistent(w, ev))
    targets = tuple(sorted({w.consumed_servings for w in consistent}))
    return ClassResult(
        key=observation_key(ev),
        evidence=ev,
        worlds=consistent,
        targets=targets,
    )


def partition(worlds: Iterable[World], evidence_of: Callable[[World], Evidence]) -> list[ClassResult]:
    """Equivalence classes of `worlds` under the observation rendered by
    `evidence_of`. Exact: classes are grouped on the observation key."""
    groups: dict[tuple, list] = {}
    for w in worlds:
        ev = evidence_of(w)
        groups.setdefault(observation_key(ev), []).append((w, ev))
    results = []
    for key in sorted(groups, key=repr):
        members = groups[key]
        ws = tuple(w for w, _ in members)
        targets = tuple(sorted({w.consumed_servings for w in ws}))
        results.append(ClassResult(key=key, evidence=members[0][1], worlds=ws, targets=targets))
    return results


def find_outcome_leak(worlds, candidate_key_of_world, honest_key_of_world) -> dict | None:
    """Detect a leaked outcome field in a key builder.

    Groups `worlds` by `honest_key_of_world` (the observation-only key). Inside
    any group whose members disagree on the target, the candidate key must
    still agree — it sees the same observations. If it separates them, it used
    the outcome (or another latent fact): that is the leak. Returns a witness
    dict, or None when the candidate key is honest.
    """
    groups: dict[tuple, list] = defaultdict(list)
    for w in worlds:
        groups[honest_key_of_world(w)].append(w)
    for honest_key, group in groups.items():
        if len(group) < 2:
            continue
        targets = sorted({w.consumed_servings for w in group})
        if len(targets) <= 1:
            continue
        candidate_keys = sorted({repr(candidate_key_of_world(w)) for w in group})
        if len(candidate_keys) > 1:
            return {
                "honest_key": repr(honest_key),
                "targets": targets,
                "candidate_keys": candidate_keys,
            }
    return None
