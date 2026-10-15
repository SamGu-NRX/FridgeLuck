"""Catalog loader and taste feature extraction.

Parses the app's bundled positional data.json (schema mirrored from
apps/ios/Platform/Persistence/Bundle/BundledDataLoader.swift) and derives the
`featureKey`s the taste spec assumes present on every catalog recipe (SPEC
section 2.1). The extractor is a documented proxy for the app's
taste-features-v1 pipeline: feature keys here are deterministic functions of
the catalog, and golden fixtures pin them as inputs, so the learned layer's
contract does not depend on extractor refinements.
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field
from typing import Dict, List, Tuple

from .constants import FEATURE_CLASSES

# data.json tag bit order (Recipe.swift RecipeTags).
TAG_BITS = (
    (1 << 0, "quick"),
    (1 << 1, "vegetarian"),
    (1 << 2, "vegan"),
    (1 << 3, "asian"),
    (1 << 4, "breakfast"),
    (1 << 5, "budget"),
    (1 << 6, "comfort"),
    (1 << 7, "mediterranean"),
    (1 << 8, "mexican"),
    (1 << 9, "high_protein"),
    (1 << 10, "low_carb"),
    (1 << 11, "one_pot"),
)

CUISINE_TAGS = {"asian", "mediterranean", "mexican"}

TECHNIQUE_KEYWORDS = (
    ("stir_fry", ("stir-fry", "stir fry", "wok", "sauté", "saute", "stir-fries")),
    ("bake", ("bake", "oven", "preheat")),
    ("grill", ("grill",)),
    ("steam", ("steam",)),
    ("boil", ("boil", "blanch")),
    ("roast", ("roast",)),
    ("simmer", ("simmer", "braise")),
    ("marinate", ("marinate", "marinade")),
)

SPICY_PATTERN = re.compile(
    r"chili|chilli|pepper flake|sriracha|sambal|cayenne|hot sauce"
    r"|jalape|harissa|gochujang|curry paste",
    re.IGNORECASE,
)


@dataclass
class Ingredient:
    id: int
    name: str
    calories: float
    protein: float
    carbs: float
    fat: float
    fiber: float
    sugar: float
    sodium: float  # grams per 100 g, as stored in data.json


@dataclass
class Recipe:
    id: str  # RecipeRef id (string per the taste contracts)
    numeric_id: int
    title: str
    time_minutes: int
    servings: int
    required: List[Tuple[int, float]]  # (ingredient id, grams)
    optional: List[Tuple[int, float]]
    instructions: str
    tag_bitmask: int
    features: List[str] = field(default_factory=list)
    feature_names: Dict[str, str] = field(default_factory=dict)

    def has_tag(self, name: str) -> bool:
        for bit, tag in TAG_BITS:
            if tag == name and self.tag_bitmask & bit:
                return True
        return False

    def feasible(self, pantry: set) -> bool:
        """True when every required ingredient id is in the pantry (the
        ranker's pantry-feasibility gate; quantities ignored, ids only)."""
        return all(ing_id in pantry for ing_id, _g in self.required)


@dataclass
class Catalog:
    recipes: Dict[str, Recipe]
    ingredients: Dict[int, Ingredient]
    feature_names: Dict[str, str]

    def sorted_ids(self) -> List[str]:
        return sorted(self.recipes)

    def all_features(self) -> List[str]:
        """Every feature key the catalog can train on, canonically sorted."""
        keys = set()
        for r in self.recipes.values():
            keys.update(r.features)
        return sorted(keys)

    def staple_ids(self) -> set:
        """Ingredients required by >= 25% of recipes: the plausible
        'always in the fridge' set the simulator starts from."""
        threshold = 0.25 * max(len(self.recipes), 1)
        counts: Dict[int, int] = {}
        for r in self.recipes.values():
            for ing_id, _g in r.required:
                counts[ing_id] = counts.get(ing_id, 0) + 1
        return {i for i, c in counts.items() if c >= threshold}

    def substitute_of(self) -> Dict[int, List[int]]:
        """Same-recipe-class substitutes: two ingredients are substitutes if
        some recipe requires one and lists the other as optional. Deterministic
        order (sorted lists)."""
        subs: Dict[int, set] = {}
        for r in self.recipes.values():
            required = {i for i, _g in r.required}
            optional = {i for i, _g in r.optional}
            for a in required & optional:
                for b in optional | required:
                    if b != a:
                        subs.setdefault(a, set()).add(b)
        return {a: sorted(v) for a, v in subs.items()}


def _feature_class(key: str) -> str:
    return key.split(":", 1)[0]


def _extract_features(recipe: Recipe, ingredients: Dict[int, Ingredient]) -> None:
    """Fills recipe.features / recipe.feature_names deterministically."""
    keys: List[str] = []

    # ingredient:<id> — required ingredients only (the app trains on what the
    # meal actually used; optional garnishes are weak identity signal).
    for ing_id, _grams in recipe.required:
        key = f"ingredient:{ing_id}"
        if key not in keys:
            keys.append(key)
            ing = ingredients.get(ing_id)
            if ing is not None:
                recipe.feature_names[key] = ing.name.lower()

    text = f"{recipe.title}\n{recipe.instructions}"

    # cuisine:<tag> — regional tags only.
    for bit, tag in TAG_BITS:
        if tag in CUISINE_TAGS and recipe.tag_bitmask & bit:
            keys.append(f"cuisine:{tag}")

    # time buckets.
    if recipe.time_minutes <= 15:
        keys.append("time:quick")
    elif recipe.time_minutes <= 30:
        keys.append("time:weeknight")
    else:
        keys.append("time:leisurely")

    # technique:<name> — first two keyword classes found in title/instructions.
    found = 0
    for tech, words in TECHNIQUE_KEYWORDS:
        if any(w in text.lower() for w in words):
            keys.append(f"technique:{tech}")
            found += 1
            if found >= 2:
                break

    # spice — one shared class key.
    if SPICY_PATTERN.search(text):
        keys.append("spice:spicy")

    # nutrient — computed after macros in load_catalog (needs per-100 g data);
    # tag-derived ones first.
    if recipe.tag_bitmask & (1 << 10):  # low_carb
        keys.append("nutrient:low_carb")
    if recipe.tag_bitmask & (1 << 9):  # high_protein
        keys.append("nutrient:high_protein")

    # tool / other.
    if recipe.tag_bitmask & (1 << 11):
        keys.append("tool:one_pot")
    for bit, tag in TAG_BITS:
        if tag in ("vegetarian", "vegan", "breakfast", "comfort", "budget"):
            if recipe.tag_bitmask & bit:
                keys.append(f"other:{tag}")

    # Deduplicate, keep stable sorted order (ranking ties and fixture output
    # expect a canonical order).
    recipe.features = sorted(set(keys))


def _macros_per_serving(recipe: Recipe, ingredients: Dict[int, Ingredient]) -> Dict[str, float]:
    """NutritionService.macros(for:) port: REQUIRED ingredients only,
    (nutrient_per_100g / 100) * grams / servings, sodium reported in mg."""
    totals = dict(cal=0.0, pro=0.0, carb=0.0, fat=0.0, fib=0.0, sug=0.0, sod=0.0)
    for ing_id, grams in recipe.required:
        ing = ingredients.get(ing_id)
        if ing is None:
            continue
        f = grams / 100.0
        totals["cal"] += ing.calories * f
        totals["pro"] += ing.protein * f
        totals["carb"] += ing.carbs * f
        totals["fat"] += ing.fat * f
        totals["fib"] += ing.fiber * f
        totals["sug"] += ing.sugar * f
        totals["sod"] += ing.sodium * f
    s = max(recipe.servings, 1)
    return {
        "calories": totals["cal"] / s,
        "protein": totals["pro"] / s,
        "carbs": totals["carb"] / s,
        "fat": totals["fat"] / s,
        "fiber": totals["fib"] / s,
        "sugar": totals["sug"] / s,
        "sodium_mg": (totals["sod"] / s) * 1000.0,
    }


def load_catalog(data_json_path: str) -> Catalog:
    with open(data_json_path, encoding="utf-8") as f:
        raw = json.load(f)

    ingredients: Dict[int, Ingredient] = {}
    for id_str, arr in raw["ingredients"].items():
        # Ingredient: [name, cal, protein, carbs, fat, fiber, sugar, sodium,
        #              unit, tip, pairsWith?, notes?]
        ingredients[int(id_str)] = Ingredient(
            id=int(id_str),
            name=arr[0],
            calories=float(arr[1]),
            protein=float(arr[2]),
            carbs=float(arr[3]),
            fat=float(arr[4]),
            fiber=float(arr[5]),
            sugar=float(arr[6]),
            sodium=float(arr[7]),
        )

    recipes: Dict[str, Recipe] = {}
    feature_names: Dict[str, str] = {}
    for arr in raw["recipes"]:
        # Recipe: [id, title, time, servings, required, optional,
        #          instructions, tagBitmask]
        recipe = Recipe(
            id=str(arr[0]),
            numeric_id=int(arr[0]),
            title=arr[1],
            time_minutes=int(arr[2]),
            servings=int(arr[3]),
            required=[(int(a), float(b)) for a, b in arr[4]],
            optional=[(int(a), float(b)) for a, b in arr[5]],
            instructions=arr[6],
            tag_bitmask=int(arr[7]),
        )
        _extract_features(recipe, ingredients)
        macros = _macros_per_serving(recipe, ingredients)
        if macros["protein"] >= 24.0 and "nutrient:high_protein" not in recipe.features:
            recipe.features.append("nutrient:high_protein")
        if macros["fiber"] >= 5.0:
            recipe.features.append("nutrient:high_fiber")
        recipe.features = sorted(set(recipe.features))
        recipes[recipe.id] = recipe

    for recipe in recipes.values():
        for key in recipe.features:
            if key not in feature_names:
                cls, name = key.split(":", 1)
                feature_names[key] = name.replace("_", " ")

    return Catalog(recipes=recipes, ingredients=ingredients, feature_names=feature_names)


def health_score_rating(
    macros: Dict[str, float],
    daily_calories: int = 2000,
    protein_pct: float = 0.25,
    carbs_pct: float = 0.45,
    fat_pct: float = 0.30,
) -> int:
    """HealthScoringService.computeScore port (default HealthProfile)."""
    points = 0.0
    meal_target = float(daily_calories) / 3.0
    ratio = macros["calories"] / meal_target
    if 0.7 <= ratio <= 1.1:
        points += 30
    elif 0.5 <= ratio < 0.7:
        points += 20
    elif 1.1 <= ratio < 1.4:
        points += 15
    else:
        points += 5

    pro_cal = macros["protein"] * 4
    carb_cal = macros["carbs"] * 4
    fat_cal = macros["fat"] * 9
    total = pro_cal + carb_cal + fat_cal
    if total > 0:
        sp, sc, sf = pro_cal / total, carb_cal / total, fat_cal / total
    else:
        sp, sc, sf = 0.33, 0.33, 0.33
    avg_diff = (abs(sp - protein_pct) + abs(sc - carbs_pct) + abs(sf - fat_pct)) / 3.0
    points += max(5.0, 40.0 * (1.0 - avg_diff * 3.0))

    if macros["fiber"] >= 5:
        points += 10
    if macros["sugar"] <= 10:
        points += 10
    if macros["sodium_mg"] <= 600:
        points += 10

    return min(5, max(1, int(math.ceil(points / 20.0))))


def feature_class(key: str) -> str:
    assert key.split(":", 1)[0] in FEATURE_CLASSES, key
    return key.split(":", 1)[0]
