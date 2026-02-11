#!/usr/bin/env python3
"""
Clean USDA catalog data for recipe-ingredient use and export to SQLite.

Pipeline:
1) Load raw catalog JSON.
2) Pre-filter obvious non-ingredient / commercial / prepared-food rows.
3) Hydrate rows with USDA /foods batch calls (format=full) to repair macros and enrich metadata.
4) Post-filter with enriched metadata.
5) Deduplicate to one row per canonical ingredient name.
6) Export clean JSON + SQLite + markdown report.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence

FDC_FOODS_URL = "https://api.nal.usda.gov/fdc/v1/foods"

DEFAULT_IN = Path("scripts/data/.cache/usda_common_food_catalog.json")
DEFAULT_OUT_JSON = Path("scripts/data/.cache/usda_cooking_ingredient_catalog_clean.json")
DEFAULT_OUT_SQLITE = Path("FridgeLuck.swiftpm/Resources/usda_ingredient_catalog.sqlite")
DEFAULT_OUT_REPORT = Path("scripts/data/.cache/usda_cooking_ingredient_catalog_report.md")

NUTRIENT_TARGETS = {
    "calories": {1008, 208},
    "protein_g": {1003, 203},
    "carbs_g": {1005, 205},
    "fat_g": {1004, 204},
    "fiber_g": {1079, 291},
    "sugar_g": {2000, 269},
    "sodium_g": {1093, 307},
}

ALLOWED_DATA_TYPES = {"Foundation", "SR Legacy"}
ZERO_MACRO_OK_TERMS = ("water", "salt", "vinegar", "spice", "herb", "extract")
MILLIGRAM_UNITS = {"mg", "milligram", "milligrams"}
MICROGRAM_UNITS = {"mcg", "ug", "µg", "microgram", "micrograms"}

PREPARED_OR_COMMERCIAL_PATTERNS = [
    re.compile(pat, re.IGNORECASE)
    for pat in (
        r"\brestaurant\b",
        r"\bfast food\b",
        r"\bfrozen dinner\b",
        r"\btv dinner\b",
        r"\bsandwich\b",
        r"\bburger\b",
        r"\bpizza\b",
        r"\bburrito\b",
        r"\btaco\b",
        r"\blasagna\b",
        r"\bstew\b",
        r"\bchili\b",
        r"\bcasserole\b",
        r"\bsnack\b",
        r"\bcandy\b",
        r"\bcookies?\b",
        r"\bcake\b",
        r"\bice cream\b",
        r"\bmilk shake\b",
        r"\bmeal replacement\b",
        r"\bbabyfood\b",
    )
]

COMPLEX_DISH_HINTS = (
    ", with ",
    " in sauce",
    " mixed dish",
    " plate",
    " platter",
)

DROPPED_FOOD_CATEGORIES = {
    "Baby Foods",
    "Restaurant Foods",
    "Meals, Entrees, and Side Dishes",
    "Beverages",
    "Sweets",
    "Baked Products",
    "Snacks",
    "Breakfast Cereals",
    "Sausages and Luncheon Meats",
    "American Indian/Alaska Native Foods",
    "Soups, Sauces, and Gravies",
}

FOOD_CATEGORY_CAPS = {
    "Beef Products": 180,
    "Pork Products": 120,
    "Poultry Products": 120,
    "Fats and Oils": 120,
}

FOOD_CATEGORY_LABEL_MAP = {
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

LOW_VALUE_PATTERN_STRINGS = (
    r"\bimitation\b",
    r"\breplacement\b",
    r"\bsubstitute\b",
    r"\brotisserie\b",
    r"\binstant breakfast\b",
    r"\bmeatless\b",
    r"\bbacon bits?\b",
    r"\bflavor(ed|ing)\b",
    r"\bseasoning mix\b",
    r"\bpowdered drink\b",
    r"\bjuice cocktail\b",
    r"\bheavy syrup\b",
    r"\blight syrup\b",
    r"\bjellied\b",
    r"\bcandied\b",
    r"\bdressing\b",
    r"\bmayonnaise\b",
    r"\bmargarine\b",
    r"\bspread\b",
    r"\bsmoothie\b",
    r"\breduced calorie\b",
    r"\bfat[- ]free\b",
    r"\bcholesterol[- ]free\b",
    r"\bdiet\b",
    r"\blow sodium\b",
    r"\blightly salted\b",
    r"\bhoney roasted\b",
    r"\boil roasted\b",
)
LOW_VALUE_PATTERNS = [re.compile(pattern, re.IGNORECASE) for pattern in LOW_VALUE_PATTERN_STRINGS]

NAME_PART_DROP_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in (
        r"\b(raw|fresh|uncooked|cooked|broiled|braised|boiled|fried|roasted|baked|stewed|steamed|microwaved|grilled)\b",
        r"\b(canned|frozen|drained|solids|liquids|regular pack|water pack|vacuum pack|no salt added|without salt|with salt)\b",
        r"\b(trimmed|separable|lean|fat|all grades|choice|select|prime|ns as to fat)\b",
        r"\b(skinless|boneless|meat only|meat and skin)\b",
        r"\b(broiler or fryers|broilers or fryers)\b",
        r"\b(heavy syrup|light syrup|sweetened|unsweetened|jellied)\b",
    )
]

NAME_TOKEN_STOPWORDS = {
    "and",
    "or",
    "with",
    "without",
    "no",
    "added",
    "all",
    "grades",
    "choice",
    "select",
    "type",
    "style",
    "styles",
    "as",
    "to",
    "ns",
}

CATEGORY_NAME_PART_LIMITS = {
    "protein": 2,
    "vegetable": 2,
    "fruit": 2,
    "grain_legume": 3,
    "dairy_egg": 2,
    "oil_fat": 2,
    "herb_spice": 2,
    "nut_seed": 3,
    "fungi": 2,
    "condiment": 3,
    "sweetener_baking": 2,
}


def canonical_name(raw: str) -> str:
    return re.sub(r"\s+", " ", raw.strip().lower())


def deparenthesize(raw: str) -> str:
    return re.sub(r"\([^)]*\)", "", raw).strip()


def get_field(item: Any, *keys: str, default: Any = None) -> Any:
    if isinstance(item, dict):
        for key in keys:
            if key in item and item[key] is not None:
                return item[key]
    return default


def to_int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def to_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def chunked(values: Sequence[int], size: int) -> Iterable[List[int]]:
    step = max(1, size)
    for idx in range(0, len(values), step):
        yield list(values[idx : idx + step])


def post_json(url: str, payload: Dict[str, Any], headers: Dict[str, str]) -> Any:
    request = urllib.request.Request(
        url=url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def nutrient_value(food_nutrients: Sequence[Any], nutrient_targets: set[int], *, as_grams: bool = False) -> float:
    for nutrient in food_nutrients:
        nutrient_obj = get_field(nutrient, "nutrient", default={}) or {}
        nutrient_id = to_int(get_field(nutrient, "nutrientId", "nutrient_id", "id"))
        if nutrient_id is None:
            nutrient_id = to_int(get_field(nutrient_obj, "id"))
        nutrient_nbr = to_int(get_field(nutrient, "nutrientNumber", "nutrient_nbr", "nutrientNbr", "number"))
        if nutrient_nbr is None:
            nutrient_nbr = to_int(get_field(nutrient_obj, "number"))

        if nutrient_id not in nutrient_targets and nutrient_nbr not in nutrient_targets:
            continue

        value = to_float(get_field(nutrient, "value", "amount"))
        if value is not None:
            if as_grams:
                unit_name = canonical_name(
                    str(get_field(nutrient, "unitName", "unit_name", default=get_field(nutrient_obj, "unitName", "unit_name", default="")) or "")
                )
                if unit_name in MILLIGRAM_UNITS:
                    value /= 1000.0
                elif unit_name in MICROGRAM_UNITS:
                    value /= 1_000_000.0
            return value
    return 0.0


def extract_macros(food: Any) -> Dict[str, float]:
    nutrients = get_field(food, "foodNutrients", "food_nutrients", "nutrients", default=[]) or []
    return {
        "calories": round(nutrient_value(nutrients, NUTRIENT_TARGETS["calories"]), 4),
        "protein_g": round(nutrient_value(nutrients, NUTRIENT_TARGETS["protein_g"]), 4),
        "carbs_g": round(nutrient_value(nutrients, NUTRIENT_TARGETS["carbs_g"]), 4),
        "fat_g": round(nutrient_value(nutrients, NUTRIENT_TARGETS["fat_g"]), 4),
        "fiber_g": round(nutrient_value(nutrients, NUTRIENT_TARGETS["fiber_g"]), 4),
        "sugar_g": round(nutrient_value(nutrients, NUTRIENT_TARGETS["sugar_g"]), 4),
        "sodium_g": round(nutrient_value(nutrients, NUTRIENT_TARGETS["sodium_g"], as_grams=True), 4),
    }


def is_obviously_prepared_or_commercial(description_norm: str) -> bool:
    if any(pattern.search(description_norm) for pattern in PREPARED_OR_COMMERCIAL_PATTERNS):
        return True
    if any(token in description_norm for token in COMPLEX_DISH_HINTS):
        return True
    return False


def looks_like_brand_heading(description: str) -> bool:
    head = (description.split(",", 1)[0] or "").strip()
    letters = [ch for ch in head if ch.isalpha()]
    if not letters:
        return False
    upper_ratio = sum(1 for ch in letters if ch.isupper()) / len(letters)
    return upper_ratio >= 0.85 and len(head.split()) <= 5


def contains_brand_signal(description: str) -> bool:
    upper_tokens = re.findall(r"\b[A-Z]{3,}\b", description)
    return bool(upper_tokens)


def is_low_value_recipe_row(description_norm: str, food_category_norm: str) -> bool:
    if any(pattern.search(description_norm) for pattern in LOW_VALUE_PATTERNS):
        return True
    if food_category_norm == "fruits and fruit juices" and any(
        term in description_norm for term in ("syrup", "candied", "jellied", "cocktail", "sauce", "smoothie")
    ):
        return True
    if food_category_norm == "dairy and egg products" and "instant breakfast" in description_norm:
        return True
    return False


def infer_category_label(description_norm: str, food_category_norm: str) -> str:
    mapped = FOOD_CATEGORY_LABEL_MAP.get(food_category_norm)
    if mapped:
        return mapped

    text = f"{description_norm} {food_category_norm}".strip()
    if any(t in text for t in ("mushroom", "fungi")):
        return "fungi"
    if any(t in text for t in ("beef", "pork", "chicken", "turkey", "lamb", "veal", "fish", "salmon", "tuna", "shrimp", "meat")):
        return "protein"
    if any(t in text for t in ("cheese", "milk", "yogurt", "cream", "egg", "dairy")):
        return "dairy_egg"
    if any(t in text for t in ("nut", "seed", "almond", "walnut", "peanut", "pistachio", "cashew", "sesame", "sunflower")):
        return "nut_seed"
    if any(t in text for t in ("bean", "lentil", "chickpea", "rice", "oat", "grain", "wheat", "pasta", "flour", "quinoa", "barley")):
        return "grain_legume"
    if any(t in text for t in ("apple", "banana", "berry", "fruit", "lemon", "lime", "orange", "avocado", "melon")):
        return "fruit"
    if any(t in text for t in ("vegetable", "onion", "garlic", "tomato", "potato", "carrot", "lettuce", "spinach", "broccoli", "cucumber", "zucchini", "celery")):
        return "vegetable"
    if any(t in text for t in ("herb", "spice", "cilantro", "parsley", "basil", "oregano")):
        return "herb_spice"
    if any(t in text for t in ("oil", "lard", "shortening", "ghee")):
        return "oil_fat"
    if any(t in text for t in ("sauce", "vinegar", "condiment", "soy sauce", "mustard", "ketchup", "tamari")):
        return "condiment"
    if any(t in text for t in ("sugar", "honey", "syrup", "sweetener", "cocoa")):
        return "sweetener_baking"
    return "other"


def normalize_name_part(raw: str) -> str:
    part = canonical_name(raw)
    part = re.sub(r"[^a-z0-9\s\-/]", " ", part)
    part = part.replace("-", " ")
    part = re.sub(r"\s+", " ", part).strip()
    return part


def should_drop_name_part(part: str) -> bool:
    if not part:
        return True
    if any(pattern.search(part) for pattern in NAME_PART_DROP_PATTERNS):
        return True
    if re.fullmatch(r"[0-9/\s]+", part):
        return True
    return False


def canonical_ingredient_name(description: str, category_label: str) -> str:
    base = deparenthesize(description)
    raw_parts = [normalize_name_part(part) for part in base.split(",")]

    kept_parts: List[str] = []
    for part in raw_parts:
        if should_drop_name_part(part):
            continue
        kept_parts.append(part)

    if not kept_parts:
        kept_parts = [part for part in raw_parts if part][:2]

    part_limit = CATEGORY_NAME_PART_LIMITS.get(category_label, 2)
    kept_parts = kept_parts[:part_limit]
    merged = " ".join(kept_parts)
    merged = re.sub(r"[^a-z0-9\s]", " ", merged)

    tokens = [token for token in re.sub(r"\s+", " ", merged).strip().split(" ") if token]
    filtered = [token for token in tokens if token not in NAME_TOKEN_STOPWORDS and not re.fullmatch(r"\d+", token)]
    out = " ".join(filtered).strip()
    return out or " ".join(tokens[:3]).strip()


def row_has_macro_signal(row: Dict[str, Any]) -> bool:
    macro_sum = (
        float(row.get("calories", 0.0) or 0.0)
        + float(row.get("protein_g", 0.0) or 0.0)
        + float(row.get("carbs_g", 0.0) or 0.0)
        + float(row.get("fat_g", 0.0) or 0.0)
        + float(row.get("fiber_g", 0.0) or 0.0)
        + float(row.get("sugar_g", 0.0) or 0.0)
        + float(row.get("sodium_g", 0.0) or 0.0)
    )
    if macro_sum > 0:
        return True
    description_norm = canonical_name(str(row.get("description", "") or ""))
    return any(term in description_norm for term in ZERO_MACRO_OK_TERMS)


def preparation_rank(description_norm: str) -> int:
    if any(term in description_norm for term in (" raw", " uncooked", " fresh")):
        return 0
    if " dried" in description_norm:
        return 1
    if " frozen" in description_norm:
        return 2
    if " canned" in description_norm:
        return 3
    if any(term in description_norm for term in (" cooked", " broiled", " braised", " boiled", " fried", " roasted", " baked")):
        return 4
    return 5


def hydrate_rows_from_usda(rows: List[Dict[str, Any]], api_key: str, delay_sec: float) -> None:
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "FridgeLuckUSDACuration/1.0 (+offline-food-recommendation-app)",
    }
    by_id: Dict[int, Dict[str, Any]] = {int(row["fdc_id"]): row for row in rows}
    ids = sorted(by_id.keys())

    for batch in chunked(ids, 20):
        payload = {"fdcIds": batch, "format": "full"}
        try:
            response = post_json(f"{FDC_FOODS_URL}?api_key={api_key}", payload, headers)
        except urllib.error.HTTPError as exc:
            print(f"Batch HTTP error ({exc.code}) for IDs {batch[:1]}..{batch[-1:]}")
            time.sleep(max(delay_sec, 0.4))
            continue
        except Exception as exc:
            print(f"Batch fetch error for IDs {batch[:1]}..{batch[-1:]}: {exc}")
            time.sleep(max(delay_sec, 0.4))
            continue

        if not isinstance(response, list):
            time.sleep(delay_sec)
            continue

        for food in response:
            fdc_id = to_int(get_field(food, "fdcId", "fdc_id"))
            if fdc_id is None or fdc_id not in by_id:
                continue
            row = by_id[fdc_id]
            row.update(extract_macros(food))

            category_obj = get_field(food, "foodCategory", "food_category", default="")
            if isinstance(category_obj, dict):
                row["food_category"] = str(get_field(category_obj, "description", "name", default="") or "")
            else:
                row["food_category"] = str(category_obj or "")

            row["food_class"] = str(get_field(food, "foodClass", "food_class", default="") or "")
            row["brand_owner"] = str(get_field(food, "brandOwner", "brand_owner", default="") or "")
            row["brand_name"] = str(get_field(food, "brandName", "brand_name", default="") or "")
            row["ingredients_text"] = str(get_field(food, "ingredients", default="") or "")

        time.sleep(delay_sec)


def load_raw_rows(path: Path) -> List[Dict[str, Any]]:
    obj = json.loads(path.read_text(encoding="utf-8"))
    records = obj.get("records", [])
    if not isinstance(records, list):
        return []

    # Older cache files stored sodium in mg while naming the field sodium_g.
    sodium_values: List[float] = []
    for raw in records:
        if not isinstance(raw, dict):
            continue
        sodium = to_float(raw.get("sodium_g"))
        if sodium is not None:
            sodium_values.append(float(sodium))
    sodium_scale = 1.0
    if sodium_values:
        sorted_sodium = sorted(sodium_values)
        median_sodium = sorted_sodium[len(sorted_sodium) // 2]
        if median_sodium > 5.0:
            sodium_scale = 0.001

    rows: List[Dict[str, Any]] = []
    for raw in records:
        if not isinstance(raw, dict):
            continue
        fdc_id = to_int(raw.get("fdc_id"))
        description = str(raw.get("description", "") or "")
        data_type = str(raw.get("data_type", "") or "")
        if fdc_id is None or not description or not data_type:
            continue
        rows.append(
            {
                "fdc_id": fdc_id,
                "description": description,
                "data_type": data_type,
                "food_category": str(raw.get("food_category", "") or ""),
                "food_code": str(raw.get("food_code", "") or ""),
                "food_class": str(raw.get("food_class", "") or ""),
                "brand_owner": str(raw.get("brand_owner", "") or ""),
                "brand_name": str(raw.get("brand_name", "") or ""),
                "ingredients_text": str(raw.get("ingredients_text", "") or ""),
                "calories": round(float(raw.get("calories", 0.0) or 0.0), 4),
                "protein_g": round(float(raw.get("protein_g", 0.0) or 0.0), 4),
                "carbs_g": round(float(raw.get("carbs_g", 0.0) or 0.0), 4),
                "fat_g": round(float(raw.get("fat_g", 0.0) or 0.0), 4),
                "fiber_g": round(float(raw.get("fiber_g", 0.0) or 0.0), 4),
                "sugar_g": round(float(raw.get("sugar_g", 0.0) or 0.0), 4),
                "sodium_g": round(float(raw.get("sodium_g", 0.0) or 0.0) * sodium_scale, 4),
            }
        )
    return rows


def curate_rows(rows: List[Dict[str, Any]]) -> tuple[List[Dict[str, Any]], Dict[str, int]]:
    reasons = Counter()

    prefiltered: List[Dict[str, Any]] = []
    seen_ids: set[int] = set()
    for row in rows:
        if row["fdc_id"] in seen_ids:
            reasons["duplicate_fdc_id"] += 1
            continue
        seen_ids.add(row["fdc_id"])

        if row["data_type"] not in ALLOWED_DATA_TYPES:
            reasons["drop_data_type"] += 1
            continue

        description_norm = canonical_name(row["description"])
        if is_obviously_prepared_or_commercial(description_norm):
            reasons["drop_prepared_or_commercial_description"] += 1
            continue

        prefiltered.append(row)

    dedup_by_name: Dict[str, Dict[str, Any]] = {}
    for row in prefiltered:
        description_norm = canonical_name(row["description"])
        if looks_like_brand_heading(row["description"]):
            reasons["drop_brand_style_heading"] += 1
            continue
        if contains_brand_signal(row["description"]):
            reasons["drop_brand_token_signal"] += 1
            continue

        food_category_norm = canonical_name(str(row.get("food_category", "") or ""))
        if not food_category_norm:
            reasons["drop_missing_food_category"] += 1
            continue
        if str(row.get("food_category", "") or "") in DROPPED_FOOD_CATEGORIES:
            reasons["drop_food_category"] += 1
            continue
        food_class_norm = canonical_name(str(row.get("food_class", "") or ""))

        if str(row.get("brand_owner", "") or "").strip() or str(row.get("brand_name", "") or "").strip():
            reasons["drop_branded_owner_name"] += 1
            continue
        if "branded" in food_class_norm:
            reasons["drop_food_class_branded"] += 1
            continue
        if is_low_value_recipe_row(description_norm, food_category_norm):
            reasons["drop_low_value_recipe_row"] += 1
            continue
        if is_obviously_prepared_or_commercial(description_norm):
            reasons["drop_prepared_or_commercial_after_hydrate"] += 1
            continue
        if not row_has_macro_signal(row):
            reasons["drop_no_macro_signal"] += 1
            continue

        category_label = infer_category_label(description_norm, food_category_norm)
        if category_label == "other":
            reasons["drop_uncategorized_other"] += 1
            continue
        normalized_name = canonical_ingredient_name(row["description"], category_label=category_label)
        if not normalized_name:
            reasons["drop_empty_normalized_name"] += 1
            continue

        cleaned = {
            "fdc_id": row["fdc_id"],
            "name": normalized_name,
            "normalized_name": normalized_name,
            "source_description": row["description"],
            "data_type": row["data_type"],
            "food_category": str(row.get("food_category", "") or ""),
            "category_label": category_label,
            "calories": round(float(row.get("calories", 0.0) or 0.0), 4),
            "protein_g": round(float(row.get("protein_g", 0.0) or 0.0), 4),
            "carbs_g": round(float(row.get("carbs_g", 0.0) or 0.0), 4),
            "fat_g": round(float(row.get("fat_g", 0.0) or 0.0), 4),
            "fiber_g": round(float(row.get("fiber_g", 0.0) or 0.0), 4),
            "sugar_g": round(float(row.get("sugar_g", 0.0) or 0.0), 4),
            "sodium_g": round(float(row.get("sodium_g", 0.0) or 0.0), 4),
        }

        existing = dedup_by_name.get(normalized_name)
        if existing is None:
            dedup_by_name[normalized_name] = cleaned
            continue

        def rank(item: Dict[str, Any]) -> tuple[int, int, int, int]:
            data_type_rank = 0 if item["data_type"] == "Foundation" else 1
            source_len = len(item["source_description"])
            macro_penalty = 0 if (item["protein_g"] + item["carbs_g"] + item["fat_g"] + item["fiber_g"]) > 0 else 1
            prep = preparation_rank(canonical_name(item["source_description"]))
            fdc_rank = int(item["fdc_id"])
            return (data_type_rank, prep, macro_penalty, source_len, fdc_rank)

        if rank(cleaned) < rank(existing):
            dedup_by_name[normalized_name] = cleaned
            reasons["dedupe_replaced_with_better_row"] += 1
        else:
            reasons["dedupe_dropped_lower_rank_row"] += 1

    curated_sorted = sorted(dedup_by_name.values(), key=lambda row: row["name"])
    limited: List[Dict[str, Any]] = []
    by_category_count: Dict[str, int] = Counter()
    for row in curated_sorted:
        category = row.get("food_category", "")
        limit = FOOD_CATEGORY_CAPS.get(category)
        if limit is not None and by_category_count[category] >= limit:
            reasons["drop_food_category_cap"] += 1
            continue
        by_category_count[category] += 1
        limited.append(row)

    return limited, dict(reasons)


def write_clean_json(path: Path, rows: List[Dict[str, Any]], reasons: Dict[str, int]) -> None:
    payload = {
        "source": "USDA FoodData Central API (cleaned for home-cooking ingredients)",
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "record_count": len(rows),
        "dropped_counts": reasons,
        "records": rows,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def write_sqlite(path: Path, rows: List[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()

    conn = sqlite3.connect(str(path))
    try:
        conn.execute(
            """
            CREATE TABLE ingredient_catalog (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fdc_id INTEGER NOT NULL UNIQUE,
                name TEXT NOT NULL UNIQUE,
                normalized_name TEXT NOT NULL UNIQUE,
                data_type TEXT NOT NULL,
                food_category TEXT NOT NULL DEFAULT '',
                category_label TEXT NOT NULL,
                calories REAL NOT NULL,
                protein REAL NOT NULL,
                carbs REAL NOT NULL,
                fat REAL NOT NULL,
                fiber REAL NOT NULL,
                sugar REAL NOT NULL,
                sodium REAL NOT NULL,
                source_description TEXT NOT NULL
            )
            """
        )
        conn.execute("CREATE INDEX idx_ingredient_catalog_name ON ingredient_catalog(name)")
        conn.execute("CREATE INDEX idx_ingredient_catalog_label ON ingredient_catalog(category_label)")

        conn.execute(
            """
            CREATE TABLE ingredients (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                calories REAL NOT NULL,
                protein REAL NOT NULL,
                carbs REAL NOT NULL,
                fat REAL NOT NULL,
                fiber REAL NOT NULL,
                sugar REAL NOT NULL,
                sodium REAL NOT NULL,
                typical_unit TEXT,
                storage_tip TEXT,
                pairs_with TEXT,
                notes TEXT
            )
            """
        )

        for row in rows:
            conn.execute(
                """
                INSERT INTO ingredient_catalog
                    (fdc_id, name, normalized_name, data_type, food_category, category_label,
                     calories, protein, carbs, fat, fiber, sugar, sodium, source_description)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    row["fdc_id"],
                    row["name"],
                    row["normalized_name"],
                    row["data_type"],
                    row["food_category"],
                    row["category_label"],
                    row["calories"],
                    row["protein_g"],
                    row["carbs_g"],
                    row["fat_g"],
                    row["fiber_g"],
                    row["sugar_g"],
                    row["sodium_g"],
                    row["source_description"],
                ),
            )
            conn.execute(
                """
                INSERT INTO ingredients
                    (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                     typical_unit, storage_tip, pairs_with, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?)
                """,
                (
                    row["fdc_id"],
                    row["name"],
                    row["calories"],
                    row["protein_g"],
                    row["carbs_g"],
                    row["fat_g"],
                    row["fiber_g"],
                    row["sugar_g"],
                    row["sodium_g"],
                    f"source={row['data_type']}; label={row['category_label']}; fdc_id={row['fdc_id']}",
                ),
            )

        conn.commit()
    finally:
        conn.close()


def write_report(path: Path, raw_count: int, hydrated_count: int, rows: List[Dict[str, Any]], reasons: Dict[str, int]) -> None:
    by_label = Counter(row["category_label"] for row in rows)
    by_type = Counter(row["data_type"] for row in rows)
    total_rows = max(1, len(rows))

    def bar(count: int, width: int = 28) -> str:
        filled = int(round((count / total_rows) * width))
        return "#" * max(0, min(width, filled))

    macro_stats: Dict[str, Dict[str, float]] = defaultdict(dict)
    for key in ("calories", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_g"):
        values = [float(row[key]) for row in rows]
        if not values:
            macro_stats[key]["mean"] = 0.0
            macro_stats[key]["median"] = 0.0
            continue
        values_sorted = sorted(values)
        mid = len(values_sorted) // 2
        median = values_sorted[mid] if len(values_sorted) % 2 == 1 else (values_sorted[mid - 1] + values_sorted[mid]) / 2
        macro_stats[key]["mean"] = round(sum(values_sorted) / len(values_sorted), 4)
        macro_stats[key]["median"] = round(median, 4)

    lines: List[str] = []
    lines.append("# USDA Cooking Ingredient Catalog Report")
    lines.append("")
    lines.append(f"- Generated at UTC: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
    lines.append(f"- Raw rows read: {raw_count}")
    lines.append(f"- Rows hydrated from USDA detail endpoint: {hydrated_count}")
    lines.append(f"- Final curated rows: {len(rows)}")
    lines.append("")
    lines.append("## Drop Reasons")
    lines.append("")
    if reasons:
        for reason, count in sorted(reasons.items(), key=lambda x: (-x[1], x[0])):
            lines.append(f"- {reason}: {count}")
    else:
        lines.append("- none")
    lines.append("")
    lines.append("## Category Label Distribution")
    lines.append("")
    for label, count in sorted(by_label.items(), key=lambda x: (-x[1], x[0])):
        pct = round((count / total_rows) * 100.0, 2)
        lines.append(f"- {label}: {count} ({pct}%) {bar(count)}")
    lines.append("")
    lines.append("## Data Type Distribution")
    lines.append("")
    for data_type, count in sorted(by_type.items(), key=lambda x: (-x[1], x[0])):
        lines.append(f"- {data_type}: {count}")
    lines.append("")
    lines.append("## Macro Summary (per 100g)")
    lines.append("")
    for key in ("calories", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g", "sodium_g"):
        lines.append(f"- {key}: mean={macro_stats[key]['mean']}, median={macro_stats[key]['median']}")
    lines.append("")
    lines.append("## Sample Rows")
    lines.append("")
    for row in rows[:20]:
        lines.append(
            "- "
            + f"{row['name']} | {row['category_label']} | kcal={row['calories']} "
            + f"P={row['protein_g']} C={row['carbs_g']} F={row['fat_g']} "
            + f"Na={row['sodium_g']}g (source: {row['source_description']})"
        )
    lines.append("")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Clean USDA ingredient catalog and export app-usable SQLite.")
    parser.add_argument("--in-catalog", type=Path, default=DEFAULT_IN, help="Input USDA catalog JSON")
    parser.add_argument("--out-json", type=Path, default=DEFAULT_OUT_JSON, help="Output cleaned JSON")
    parser.add_argument("--out-sqlite", type=Path, default=DEFAULT_OUT_SQLITE, help="Output SQLite for app usage")
    parser.add_argument("--out-report", type=Path, default=DEFAULT_OUT_REPORT, help="Output markdown report")
    parser.add_argument("--api-key", default=os.getenv("USDA_FDC_API_KEY"), help="USDA API key (or USDA_FDC_API_KEY env var)")
    parser.add_argument("--delay-sec", type=float, default=0.05, help="Delay between USDA batch requests")
    args = parser.parse_args()

    if not args.api_key:
        print("USDA_FDC_API_KEY is required for macro hydration.")
        return 1
    if not args.in_catalog.exists():
        print(f"Input catalog not found: {args.in_catalog}")
        return 1

    rows = load_raw_rows(args.in_catalog)
    raw_count = len(rows)

    # Quick prefilter before expensive hydration.
    prefiltered = []
    for row in rows:
        if row["data_type"] not in ALLOWED_DATA_TYPES:
            continue
        description_norm = canonical_name(row["description"])
        if is_obviously_prepared_or_commercial(description_norm):
            continue
        prefiltered.append(row)

    rows_to_hydrate: List[Dict[str, Any]] = []
    for row in prefiltered:
        macro_sum = (
            float(row.get("calories", 0.0) or 0.0)
            + float(row.get("protein_g", 0.0) or 0.0)
            + float(row.get("carbs_g", 0.0) or 0.0)
            + float(row.get("fat_g", 0.0) or 0.0)
            + float(row.get("fiber_g", 0.0) or 0.0)
            + float(row.get("sugar_g", 0.0) or 0.0)
            + float(row.get("sodium_g", 0.0) or 0.0)
        )
        if macro_sum <= 0.0 or not str(row.get("food_category", "") or "").strip():
            rows_to_hydrate.append(row)

    if rows_to_hydrate:
        hydrate_rows_from_usda(rows_to_hydrate, api_key=args.api_key, delay_sec=max(0.0, args.delay_sec))

    curated, reasons = curate_rows(prefiltered)
    write_clean_json(args.out_json, curated, reasons)
    write_sqlite(args.out_sqlite, curated)
    write_report(args.out_report, raw_count=raw_count, hydrated_count=len(rows_to_hydrate), rows=curated, reasons=reasons)

    print(f"Raw rows: {raw_count}")
    print(f"Hydrated rows: {len(rows_to_hydrate)}")
    print(f"Curated rows: {len(curated)}")
    print(f"Wrote clean JSON: {args.out_json}")
    print(f"Wrote SQLite: {args.out_sqlite}")
    print(f"Wrote report: {args.out_report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
