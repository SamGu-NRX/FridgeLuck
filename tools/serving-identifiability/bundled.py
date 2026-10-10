"""Loader for the app's bundled recipe metadata (apps/ios/Resources/data.json).

Layout per BundledDataLoader.RecipeArray (apps/ios/Platform/Persistence/Bundle/
BundledDataLoader.swift):

    [id, title, time_minutes, servings,
     required  [[ingredient_id, grams], ...],
     optional  [[ingredient_id, grams], ...],
     instructions, tagBitmask]

Required-ingredient grams are the batch the app's consumption model scales
(consumptionRequests scales required ingredients only); optional ingredients
are swap substitutes and do not enter the batch.
"""

from __future__ import annotations

import hashlib
import json
from fractions import Fraction
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_JSON = REPO_ROOT / "apps" / "ios" / "Resources" / "data.json"


def load_bundled_recipes(path=DATA_JSON) -> list[dict]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    recipes = []
    for r in raw["recipes"]:
        rid, title, servings, required, optional = r[0], r[1], r[3], r[4], r[5]
        recipes.append(
            {
                "recipe_id": int(rid),
                "title": str(title),
                "declared_servings": int(servings),
                "required": [(int(i), Fraction(g)) for i, g in required],
                "optional": [(int(i), Fraction(g)) for i, g in optional],
                "required_grams": sum(Fraction(g) for _, g in required),
                "optional_grams": sum(Fraction(g) for _, g in optional),
            }
        )
    return recipes


def data_json_sha256(path=DATA_JSON) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()
