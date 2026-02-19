from __future__ import annotations

import asyncio
from typing import Any

from .client_async import USDAAsyncClient
from .config import ALLOWED_DATA_TYPES, NUTRIENT_TARGETS
from .schema import CuratedIngredientRow, MacroSet, SourceMeta
from .sprite_rules import infer_sprite_group, infer_sprite_key
from .utils import MICROGRAM_UNITS, MILLIGRAM_UNITS, canonical, dedupe_keep_order, parse_parenthetical_aliases, title_case, utc_now_iso


def _to_int(value: Any) -> int | None:
    try:
        if value is None:
            return None
        return int(float(value))
    except Exception:
        return None


def _to_float(value: Any) -> float | None:
    try:
        if value is None:
            return None
        return float(value)
    except Exception:
        return None


def _get_field(item: Any, *keys: str, default: Any = None) -> Any:
    if isinstance(item, dict):
        for key in keys:
            if key in item and item[key] is not None:
                return item[key]
    return default


def nutrient_value(nutrients: list[dict[str, Any]], targets: set[int], *, as_grams: bool = False) -> float:
    for nutrient in nutrients:
        nutrient_obj = _get_field(nutrient, "nutrient", default={}) or {}
        nutrient_id = _to_int(_get_field(nutrient, "nutrientId", "id"))
        if nutrient_id is None:
            nutrient_id = _to_int(_get_field(nutrient_obj, "id"))
        nutrient_number = _to_int(_get_field(nutrient, "nutrientNumber", "number"))
        if nutrient_number is None:
            nutrient_number = _to_int(_get_field(nutrient_obj, "number"))
        if nutrient_id not in targets and nutrient_number not in targets:
            continue
        value = _to_float(_get_field(nutrient, "value", "amount"))
        if value is None:
            continue
        if as_grams:
            unit = canonical(str(_get_field(nutrient, "unitName", default=_get_field(nutrient_obj, "unitName", default="")) or ""))
            if unit in MILLIGRAM_UNITS:
                value /= 1000.0
            elif unit in MICROGRAM_UNITS:
                value /= 1_000_000.0
        return float(value)
    return 0.0


def extract_macros(food: dict[str, Any]) -> MacroSet:
    nutrients = _get_field(food, "foodNutrients", default=[]) or []
    return MacroSet(
        calories=nutrient_value(nutrients, NUTRIENT_TARGETS["calories"]),
        protein_g=nutrient_value(nutrients, NUTRIENT_TARGETS["protein_g"]),
        carbs_g=nutrient_value(nutrients, NUTRIENT_TARGETS["carbs_g"]),
        fat_g=nutrient_value(nutrients, NUTRIENT_TARGETS["fat_g"]),
        fiber_g=nutrient_value(nutrients, NUTRIENT_TARGETS["fiber_g"]),
        sugar_g=nutrient_value(nutrients, NUTRIENT_TARGETS["sugar_g"]),
        sodium_g=nutrient_value(nutrients, NUTRIENT_TARGETS["sodium_g"], as_grams=True),
    )


def infer_category_label(description: str, food_category: str) -> str:
    d = canonical(description)
    c = canonical(food_category)
    lookup = {
        "beef products": "protein",
        "pork products": "protein",
        "poultry products": "protein",
        "lamb, veal, and game products": "protein",
        "finfish and shellfish products": "protein",
        "dairy and egg products": "dairy_egg",
        "vegetables and vegetable products": "vegetable",
        "fruits and fruit juices": "fruit",
        "cereal grains and pasta": "grain_legume",
        "legumes and legume products": "grain_legume",
        "nut and seed products": "nut_seed",
        "spices and herbs": "herb_spice",
        "fats and oils": "oil_fat",
        "soups, sauces, and gravies": "condiment",
    }
    if c in lookup:
        return lookup[c]
    text = f"{d} {c}"
    if any(t in text for t in ("beef", "pork", "chicken", "turkey", "lamb", "fish", "shrimp", "meat", "tuna")):
        return "protein"
    if any(t in text for t in ("milk", "cheese", "yogurt", "egg", "cream", "dairy")):
        return "dairy_egg"
    if any(t in text for t in ("bean", "lentil", "rice", "oat", "grain", "flour", "pasta", "chickpea", "quinoa")):
        return "grain_legume"
    if any(t in text for t in ("oil", "lard", "ghee", "shortening")):
        return "oil_fat"
    if any(t in text for t in ("pepper", "spice", "herb", "cilantro", "basil", "oregano")):
        return "herb_spice"
    if any(t in text for t in ("onion", "garlic", "tomato", "celery", "lettuce", "broccoli", "spinach", "cucumber", "zucchini", "carrot", "pepper")):
        return "vegetable"
    if any(t in text for t in ("apple", "banana", "orange", "lemon", "lime", "berry", "fruit", "avocado", "grape")):
        return "fruit"
    return "other"


def infer_display_name(description: str) -> str:
    d = canonical(description)
    if d.startswith("spices, pepper, black"):
        return "Black Pepper"
    if d.startswith("spices, pepper, red") or "red or cayenne" in d:
        return "Red Pepper (Cayenne/Flakes)"
    if d.startswith("spices, pepper, white"):
        return "White Pepper"
    if d.startswith("onions, spring or scallions"):
        return "Green Onions (Scallions)"
    if d.startswith("oil, olive"):
        return "Olive Oil"
    if d.startswith("fish, tuna") and "canned" in d:
        packed = "Water-Packed" if "water" in d else "Oil-Packed" if "oil" in d else "Canned"
        tuna_type = "Light" if "light" in d else "White" if "white" in d else ""
        core = f"{tuna_type} Tuna".strip()
        return f"Canned {core} ({packed})"
    if d.startswith("beans, black") and "cooked" in d:
        return "Black Beans (Cooked)"
    if d.startswith("milk"):
        if "2%" in d:
            return "Milk (2% Reduced Fat)"
        if "1%" in d:
            return "Milk (1% Low Fat)"
        if any(t in d for t in ("skim", "nonfat", "fat free")):
            return "Milk (Skim)"
        if "whole" in d:
            return "Milk (Whole)"
    parts = [p.strip() for p in description.split(",") if p.strip()]
    return title_case(parts[0]) if parts else title_case(description)


def infer_aliases(display_name: str, source_description: str) -> list[str]:
    aliases = [canonical(display_name)]
    aliases.extend(parse_parenthetical_aliases(source_description))
    d = canonical(source_description)
    if "scallions" in d:
        aliases.extend(["green onion", "green onions", "scallion", "spring onion"])
    if "spices, pepper, black" in d:
        aliases.extend(["black pepper", "ground black pepper", "pepper"])
    if "spices, pepper, red" in d or "red or cayenne" in d:
        aliases.extend(["red pepper flakes", "crushed red pepper", "cayenne pepper"])
    if d.startswith("milk") and "2%" in d:
        aliases.extend(["2% milk", "2 percent milk", "reduced fat milk"])
    if d.startswith("milk") and "1%" in d:
        aliases.extend(["1% milk", "1 percent milk", "low fat milk"])
    if d.startswith("milk") and any(t in d for t in ("skim", "nonfat", "fat free")):
        aliases.extend(["skim milk", "nonfat milk", "fat free milk"])
    if "fish, tuna" in d and "canned" in d:
        aliases.extend(["canned tuna", "tuna canned"])
    return dedupe_keep_order(aliases)


def infer_description(category_label: str, source_description: str) -> str:
    category_map = {
        "protein": "Protein ingredient",
        "vegetable": "Vegetable ingredient",
        "fruit": "Fruit ingredient",
        "grain_legume": "Grain or legume ingredient",
        "dairy_egg": "Dairy or egg ingredient",
        "oil_fat": "Oil or fat ingredient",
        "herb_spice": "Herb or spice ingredient",
        "nut_seed": "Nut or seed ingredient",
        "condiment": "Condiment ingredient",
        "sweetener_baking": "Baking sweetener ingredient",
        "fungi": "Mushroom ingredient",
        "other": "Ingredient",
    }
    prep = []
    d = canonical(source_description)
    for token in ("raw", "cooked", "canned", "frozen", "dried", "pickled", "rotisserie"):
        if token in d:
            prep.append(token)
    prep_part = prep[0] if prep else "listed"
    return f"{category_map.get(category_label, 'Ingredient')} in {prep_part} form; nutrition values are per 100g."


def score_candidate(query: str, food: dict[str, Any]) -> float:
    q = canonical(query)
    desc = canonical(str(food.get("description", "") or ""))
    data_type = canonical(str(food.get("dataType", "") or ""))
    brand_owner = canonical(str(food.get("brandOwner", "") or ""))
    score = 0.0
    if q in desc:
        score += 3.0
    q_tokens = [t for t in q.split(" ") if t]
    hits = sum(1 for t in q_tokens if t in desc)
    score += hits / max(1, len(q_tokens))
    if "foundation" in data_type:
        score += 0.5
    if "branded" in data_type or brand_owner:
        score -= 2.0
    return score


def is_disallowed(description: str) -> bool:
    d = canonical(description)
    bad = [
        "restaurant",
        "fast food",
        "kids menu",
        "meal replacement",
        "instant breakfast",
        "milk shakes",
        "frozen dinner",
        "tv dinner",
    ]
    return any(t in d for t in bad)


def normalize_query_variants(query: str) -> list[str]:
    q = canonical(query)
    variants = [q]
    extra = {
        "2% milk": ["milk reduced fat 2% milkfat", "milk 2 percent"],
        "1% milk": ["milk low fat 1% milkfat", "milk 1 percent"],
        "skim milk": ["milk fat free", "milk nonfat"],
        "frozen peas": ["peas green frozen cooked", "peas green frozen"],
        "canned tuna": ["tuna canned in water", "tuna canned"],
        "green onion": ["onions spring or scallions", "scallions raw"],
        "red pepper flakes": ["spices pepper red or cayenne", "crushed red pepper"],
    }
    variants.extend(extra.get(q, []))
    return dedupe_keep_order(variants)


async def fetch_candidates(
    client: USDAAsyncClient,
    *,
    queries: list[str],
    add_fdc_ids: list[int],
) -> list[CuratedIngredientRow]:
    out_by_id: dict[int, CuratedIngredientRow] = {}

    if add_fdc_ids:
        details = await client.get_foods([int(v) for v in add_fdc_ids])
        for fdc_id, detail in details.items():
            row = row_from_food(detail)
            if row is not None:
                out_by_id[fdc_id] = row

    ranking_tasks = [_rank_fdc_ids_for_query(client, query) for query in queries]
    ranking_results = await asyncio.gather(*ranking_tasks, return_exceptions=True)

    ranked_by_query: dict[str, list[int]] = {}
    detail_ids: set[int] = set()
    for query, result in zip(queries, ranking_results):
        if isinstance(result, Exception) or not result:
            continue
        ranked_ids = [int(v) for v in result]
        ranked_by_query[query] = ranked_ids
        detail_ids.update(ranked_ids)

    details = await client.get_foods(sorted(detail_ids))
    for query in queries:
        ranked_ids = ranked_by_query.get(query, [])
        for fdc_id in ranked_ids:
            detail = details.get(fdc_id)
            if not isinstance(detail, dict):
                continue
            row = row_from_food(detail)
            if row is not None:
                out_by_id[row.fdc_id] = row
                break

    return sorted(out_by_id.values(), key=lambda row: row.fdc_id)


async def _rank_fdc_ids_for_query(client: USDAAsyncClient, query: str, top_k: int = 4) -> list[int]:
    variants = normalize_query_variants(query)
    search_tasks = [client.search(variant, data_types=list(ALLOWED_DATA_TYPES), page_size=40) for variant in variants]
    search_results = await asyncio.gather(*search_tasks, return_exceptions=True)

    ranked: dict[int, float] = {}
    for foods in search_results:
        if isinstance(foods, Exception):
            continue
        for food in foods:
            fdc_id = _to_int(food.get("fdcId"))
            if fdc_id is None:
                continue
            if is_disallowed(str(food.get("description", "") or "")):
                continue
            score = score_candidate(query, food)
            if fdc_id not in ranked or score > ranked[fdc_id]:
                ranked[fdc_id] = score

    if not ranked:
        return []
    ordered = sorted(ranked.items(), key=lambda item: (item[1], item[0]), reverse=True)
    return [fdc_id for fdc_id, _ in ordered[:top_k]]


def row_from_food(food: dict[str, Any]) -> CuratedIngredientRow | None:
    fdc_id = _to_int(food.get("fdcId"))
    if fdc_id is None:
        return None
    description = str(food.get("description", "") or "").strip()
    data_type = str(food.get("dataType", "") or "").strip()
    if not description or data_type not in ALLOWED_DATA_TYPES:
        return None
    category_obj = food.get("foodCategory")
    if isinstance(category_obj, dict):
        food_category = str(category_obj.get("description", "") or "")
    else:
        food_category = str(category_obj or "")

    category_label = infer_category_label(description, food_category)
    display_name = infer_display_name(description)
    aliases = infer_aliases(display_name, description)
    sprite_group = infer_sprite_group(category_label)
    sprite_key = infer_sprite_key(display_name, description)
    description_text = infer_description(category_label, description)

    return CuratedIngredientRow(
        fdc_id=fdc_id,
        display_name=display_name,
        alt_names=aliases,
        category_label=category_label,
        sprite_group=sprite_group,
        sprite_key=sprite_key,
        description=description_text,
        source_description=description,
        source_meta=SourceMeta(
            data_type=data_type,
            food_category=food_category,
            verified_at_utc=utc_now_iso(),
            verification_source="USDA FoodData Central API",
        ),
        macros=extract_macros(food),
    )
