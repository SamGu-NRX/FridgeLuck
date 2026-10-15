#!/usr/bin/env python3
"""Independent feasibility oracle for FridgeLuck pantry-feasibility evaluation.

This oracle is specified directly from the DATA MODEL (Recipe.swift,
Inventory.swift, HealthProfile.swift, AllergenGroupMembership.swift) and is
deliberately NOT a transcription of the RecipeRepository SQL query.

The production query (apps/ios/Platform/Persistence/Repository/
RecipeRepository.swift, `queryRecipes`) decides "makeable" purely from
required-ingredient ID membership: it never compares the recipe's
`quantity_grams` against the pantry's remaining grams. The oracle below
implements the data model's own semantics:

  A recipe is FEASIBLE (cookable) for a pantry state iff
    1. Every required recipe_ingredient row has enough on hand:
         sum of known remaining grams for that ingredient >= row quantity_grams.
       A pantry lot whose quantity is an estimate (`quantity_is_estimate`)
       carries a UNKNOWN amount; an unknown amount cannot refute feasibility,
       so its presence satisfies the requirement and is recorded as a
       quantity assumption. The oracle never invents a number for it.
       A lot with 0 remaining grams contributes nothing (the item is gone).
    2. NO ingredient of the recipe (required OR optional) is in the state's
       effective exclusion set: explicitly selected allergen-group members
       UNION individually excluded ingredient IDs UNION diet-excluded IDs.
    3. The recipe carries every tag the diet requires (tag mask subset).

Optional ingredients never block feasibility.

The oracle's allergen-group membership table and diet constants are
transcribed from the domain sources of truth (AllergenGroupMembership.swift,
HealthProfile.swift). The SwiftReplay harness cross-checks these constants
against the real Swift types at replay time, so any drift between this
transcription and production surfaces as a crosscheck failure rather than
silently skewing results.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Data-model constants (transcribed from HealthProfile.swift / Recipe.swift)
# ---------------------------------------------------------------------------

# RecipeTags bitmask (Recipe.swift).
TAG_BITS = {
    "quick": 1 << 0,
    "vegetarian": 1 << 1,
    "vegan": 1 << 2,
    "asian": 1 << 3,
    "breakfast": 1 << 4,
    "budget": 1 << 5,
    "comfort": 1 << 6,
    "mediterranean": 1 << 7,
    "mexican": 1 << 8,
    "high_protein": 1 << 9,
    "low_carb": 1 << 10,
    "one_pot": 1 << 11,
}

# Diet -> required tag mask (HealthProfile.requiredRecipeTagMask).
DIET_TAG_MASK = {
    "vegan": TAG_BITS["vegan"],
    "vegetarian": TAG_BITS["vegetarian"],
    "keto": TAG_BITS["low_carb"],
    "pescatarian": 0,
    "": 0,
    None: 0,
}

# Diet -> ingredient IDs excluded outright (HealthProfile.dietaryExcludedIngredientIds).
DIET_EXCLUDED_IDS = {
    "vegan": {12, 13, 14, 32, 50},  # cheese, milk, butter, yogurt, sour cream
    "vegetarian": set(),
    "keto": set(),
    "pescatarian": set(),
    "": set(),
    None: set(),
}

# Canonical allergen group IDs (AllergenGroupID raw values).
GROUP_IDS = {
    "milk",
    "egg",
    "peanut",
    "tree_nut",
    "wheat_gluten",
    "soy",
    "fish",
    "shellfish",
    "sesame",
    "mustard",
}

# AllergenExclusions.coreMemberships: bundled core ingredient ID -> group set.
# (50 rows; safe ingredients are listed with an empty set so the table is
# exhaustive, mirroring the Swift source.)
CORE_MEMBERSHIPS: dict[int, set[str]] = {
    1: {"egg"},
    2: set(),
    3: {"soy", "wheat_gluten"},
    4: set(),
    5: set(),
    6: set(),
    7: set(),
    8: set(),
    9: {"wheat_gluten"},
    10: set(),
    11: set(),
    12: {"milk"},
    13: {"milk"},
    14: {"milk"},
    15: {"wheat_gluten"},
    16: set(),
    17: set(),
    18: set(),
    19: set(),
    20: set(),
    21: set(),
    22: {"sesame"},
    23: {"soy"},
    24: set(),
    25: set(),
    26: set(),
    27: set(),
    28: {"wheat_gluten"},
    29: set(),
    30: set(),
    31: {"wheat_gluten"},
    32: {"milk"},
    33: set(),
    34: set(),
    35: set(),
    36: {"fish"},
    37: set(),
    38: set(),
    39: set(),
    40: set(),
    41: {"peanut"},
    42: set(),
    43: {"fish"},
    44: set(),
    45: set(),
    46: set(),
    47: set(),
    48: set(),
    49: {"tree_nut"},
    50: {"milk"},
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Catalog snapshot
# ---------------------------------------------------------------------------

@dataclass
class RecipeRow:
    recipe_id: int
    title: str
    time_minutes: int
    tags: int
    required: tuple[tuple[int, float], ...]
    optional: tuple[tuple[int, float], ...]


@dataclass
class Catalog:
    """Frozen catalog snapshot extracted once from apps/ios/Resources/data.json."""

    recipes: dict[int, RecipeRow]
    ingredient_names: dict[int, str]
    source_sha256: str = ""

    @classmethod
    def load(cls, path: Path) -> "Catalog":
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        recipes = {
            int(rid): RecipeRow(
                recipe_id=int(rid),
                title=r["title"],
                time_minutes=int(r["time_minutes"]),
                tags=int(r["tags"]),
                required=tuple((int(i), float(g)) for i, g in r["required"]),
                optional=tuple((int(i), float(g)) for i, g in r["optional"]),
            )
            for rid, r in raw["recipes"].items()
        }
        return cls(
            recipes=recipes,
            ingredient_names={int(k): v for k, v in raw["ingredient_names"].items()},
            source_sha256=raw.get("provenance", {}).get("source_sha256", ""),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "recipes": {
                str(r.recipe_id): {
                    "title": r.title,
                    "time_minutes": r.time_minutes,
                    "tags": r.tags,
                    "required": [[i, g] for i, g in r.required],
                    "optional": [[i, g] for i, g in r.optional],
                }
                for r in sorted(self.recipes.values(), key=lambda r: r.recipe_id)
            },
            "ingredient_names": {str(k): v for k, v in sorted(self.ingredient_names.items())},
            "provenance": {"source_sha256": self.source_sha256},
        }


# ---------------------------------------------------------------------------
# Verdicts
# ---------------------------------------------------------------------------

@dataclass
class Verdict:
    feasible: bool
    # required ingredient IDs with no pantry presence at all
    missing_required_ids: list[int] = field(default_factory=list)
    # required ingredient IDs present but with known grams below the requirement
    insufficient: list[dict[str, float]] = field(default_factory=list)
    # required ingredient IDs satisfied only by unknown (estimated) quantity
    unknown_quantity_assumptions: list[int] = field(default_factory=list)
    # ingredient IDs (required or optional) excluded by allergens/diet
    excluded_ids: list[int] = field(default_factory=list)
    # recipe lacks a diet-required tag
    tag_violation: bool = False

    @property
    def infeasible_reasons(self) -> list[str]:
        reasons = []
        if self.missing_required_ids:
            reasons.append("missing_required_ingredient")
        if self.insufficient:
            reasons.append("insufficient_known_quantity")
        if self.excluded_ids:
            reasons.append("excluded_ingredient")
        if self.tag_violation:
            reasons.append("diet_tag_violation")
        return reasons


class FeasibilityOracle:
    """Independent, exact feasibility evaluator specified from the data model."""

    def __init__(self, catalog: Catalog):
        self.catalog = catalog

    # -- profile semantics (data model: HealthProfile + AllergenExclusions) --

    def effective_exclusions(self, profile: dict[str, Any]) -> set[int]:
        groups = set(profile.get("allergen_groups") or [])
        unknown = groups - GROUP_IDS
        if unknown:
            # Mirrors AllergenExclusions.normalizedGroupIDs: unknown group
            # strings are dropped, never honored, never guessed.
            groups = groups & GROUP_IDS
        excluded: set[int] = set()
        for ingredient_id, member_groups in CORE_MEMBERSHIPS.items():
            if member_groups & groups:
                excluded.add(ingredient_id)
        excluded |= set(profile.get("allergen_ingredient_ids") or [])
        excluded |= DIET_EXCLUDED_IDS.get(profile.get("diet"), set())
        return excluded

    def required_tag_mask(self, profile: dict[str, Any]) -> int:
        return DIET_TAG_MASK.get(profile.get("diet"), 0)

    # -- pantry semantics (data model: inventory_lots / remaining grams) --

    def pantry_totals(self, state: dict[str, Any]) -> dict[int, dict[str, Any]]:
        """Aggregate pantry lots per ingredient.

        Returns ingredient_id -> {"known_grams": float|None, "is_estimate": bool}.
        known_grams is None when every lot for the ingredient is an estimate:
        the amount is unknown and the oracle refuses to invent one.
        """
        totals: dict[int, dict[str, Any]] = {}
        for lot in state.get("pantry", []):
            ingredient_id = int(lot["ingredient_id"])
            entry = totals.setdefault(ingredient_id, {"known_grams": 0.0, "is_estimate": False})
            if lot.get("is_estimate") or lot.get("known_grams") is None:
                entry["is_estimate"] = True
            else:
                entry["known_grams"] += float(lot["known_grams"])
        return totals

    def available_ids(self, state: dict[str, Any]) -> set[int]:
        """IDs production's search receives: any pantry row still holding food.

        A row with a known 0 remaining amount is exhausted and never reaches
        the available set. An unknown (estimated) amount stays in the set:
        presence is all that is known.
        """
        out: set[int] = set()
        for ingredient_id, entry in self.pantry_totals(state).items():
            known = entry["known_grams"]
            if entry["is_estimate"] or known > 0:
                out.add(ingredient_id)
        return out

    # -- the feasibility definition --

    def evaluate_recipe(self, state: dict[str, Any], recipe: RecipeRow) -> Verdict:
        profile = state.get("profile", {})
        excluded = self.effective_exclusions(profile)
        mask = self.required_tag_mask(profile)
        totals = self.pantry_totals(state)

        verdict = Verdict(feasible=False)

        if recipe.tags & mask != mask:
            verdict.tag_violation = True

        for ingredient_id, grams in recipe.required:
            if ingredient_id in excluded:
                verdict.excluded_ids.append(ingredient_id)
                continue
            entry = totals.get(ingredient_id)
            if entry is None:
                verdict.missing_required_ids.append(ingredient_id)
                continue
            if entry["is_estimate"]:
                verdict.unknown_quantity_assumptions.append(ingredient_id)
                continue
            if entry["known_grams"] + 1e-9 < grams:
                verdict.insufficient.append(
                    {
                        "ingredient_id": ingredient_id,
                        "required_grams": grams,
                        "available_grams": entry["known_grams"],
                    }
                )

        # Exclusions apply to optional rows too (data model: an allergen in the
        # dish is an allergen in the dish, required or not).
        for ingredient_id, _grams in recipe.optional:
            if ingredient_id in excluded:
                verdict.excluded_ids.append(ingredient_id)

        verdict.missing_required_ids.sort()
        verdict.unknown_quantity_assumptions.sort()
        verdict.excluded_ids = sorted(set(verdict.excluded_ids))
        verdict.feasible = not verdict.infeasible_reasons
        return verdict

    def evaluate_all(self, state: dict[str, Any]) -> dict[int, Verdict]:
        return {rid: self.evaluate_recipe(state, r) for rid, r in self.catalog.recipes.items()}


def load_oracle(tool_dir: Path) -> tuple[FeasibilityOracle, Catalog]:
    catalog = Catalog.load(Path(tool_dir) / "runs" / "catalog_snapshot.json")
    return FeasibilityOracle(catalog), catalog


def load_states(tool_dir: Path) -> list[dict[str, Any]]:
    states_path = Path(tool_dir) / "runs" / "states.jsonl"
    states = []
    with open(states_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                states.append(json.loads(line))
    return states
