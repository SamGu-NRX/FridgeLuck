#!/usr/bin/env python3
"""
Collect ingredient nutrition data from USDA FoodData Central and compact it for FridgeLuck.

Primary behavior:
- Read ingredient IDs/names from FridgeLuck's bundled `data.json`.
- Query USDA FDC for each ingredient.
- Select the best candidate by text + macro similarity to current bundled baseline.
- Output a compact JSON payload that can be embedded as static Swift data.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Sequence

try:
    from usda_fdc import FdcApiError, FdcAuthError, FdcClient, FdcRateLimitError
except Exception:
    FdcApiError = FdcAuthError = FdcRateLimitError = None
    FdcClient = None

FDC_SEARCH_URL = "https://api.nal.usda.gov/fdc/v1/foods/search"
FDC_FOOD_URL = "https://api.nal.usda.gov/fdc/v1/food"
FDC_FOODS_URL = "https://api.nal.usda.gov/fdc/v1/foods"
FDC_FOODS_LIST_URL = "https://api.nal.usda.gov/fdc/v1/foods/list"

DEFAULT_INPUT = Path("apps/ios/Resources/data.json")
DEFAULT_OUTPUT = Path("apps/ios/Resources/usda_ingredient_nutrition_compact.json")
DEFAULT_CATALOG = Path("scripts/data/.cache/usda_common_food_catalog.json")

SEARCH_DATA_TYPES = ["Foundation", "SR Legacy", "Survey (FNDDS)"]
STOP_WORDS = {"and", "or", "of", "the", "a", "an"}
SEARCH_DATA_TYPE_PASSES = [
    ["Foundation"],
    ["SR Legacy", "Survey (FNDDS)"],
]

# For ingredient catalogs used by recipes, prefer USDA primary ingredient datasets.
CATALOG_DATA_TYPES = ["Foundation", "SR Legacy", "Survey (FNDDS)"]
NUTRIENT_TARGETS = {
    "calories": {1008, 208},
    "protein_g": {1003, 203},
    "carbs_g": {1005, 205},
    "fat_g": {1004, 204},
    "fiber_g": {1079, 291},
    "sugar_g": {2000, 269},
    "sodium_g": {1093, 307},
}
MILLIGRAM_UNITS = {"mg", "milligram", "milligrams"}
MICROGRAM_UNITS = {"mcg", "ug", "µg", "microgram", "micrograms"}
# Context7 docs: nutrient filters are supported, but payload shape is inconsistent across
# endpoints/datatypes; we fetch complete nutrient rows for correctness.
NUTRIENT_FILTER: List[int] = []

ALIASES: Dict[str, List[str]] = {
    "green_onion": ["green onion", "scallion"],
    "canned_tuna": ["tuna canned in water", "tuna"],
    "ground_beef": ["beef ground cooked 85% lean", "ground beef cooked"],
    "red_pepper_flakes": ["red pepper flakes", "chili flakes"],
    "peanut_butter": ["peanut butter smooth", "peanut butter"],
    "soy_sauce": ["soy sauce tamari", "soy sauce"],
    "coconut_milk": ["coconut milk canned"],
    "sweet_potato": ["sweet potato baked", "sweet potato"],
    "bell_pepper": ["bell pepper", "sweet pepper"],
    "black_beans": ["black beans cooked", "black beans canned", "black beans"],
    "chickpea": ["chickpeas cooked", "chickpeas canned", "chickpeas"],
    "rice": ["rice cooked", "rice white cooked"],
    "pasta": ["pasta cooked", "spaghetti cooked"],
    "chicken_breast": ["chicken breast cooked", "chicken breast"],
    "oats": ["oats dry", "rolled oats"],
    "frozen_peas": ["green peas cooked", "peas frozen", "green peas"],
}

CATEGORY_HINTS: Dict[str, List[str]] = {
    "egg": ["dairy and egg products"],
    "cheese": ["dairy and egg products"],
    "milk": ["dairy and egg products"],
    "yogurt": ["dairy and egg products"],
    "butter": ["dairy and egg products", "fats and oils"],
    "sour cream": ["dairy and egg products"],
    "chicken breast": ["poultry products"],
    "ground beef": ["beef products"],
    "salmon": ["finfish and shellfish products"],
    "canned tuna": ["finfish and shellfish products"],
    "tofu": ["legumes and legume products"],
    "onion": ["vegetables and vegetable products"],
    "garlic": ["vegetables and vegetable products"],
    "tomato": ["vegetables and vegetable products"],
    "bell pepper": ["vegetables and vegetable products"],
    "potato": ["vegetables and vegetable products"],
    "carrot": ["vegetables and vegetable products"],
    "mushroom": ["vegetables and vegetable products"],
    "spinach": ["vegetables and vegetable products"],
    "green onion": ["vegetables and vegetable products"],
    "broccoli": ["vegetables and vegetable products"],
    "cucumber": ["vegetables and vegetable products"],
    "black beans": ["legumes and legume products"],
    "chickpea": ["legumes and legume products"],
    "sweet potato": ["vegetables and vegetable products"],
    "lettuce": ["vegetables and vegetable products"],
    "celery": ["vegetables and vegetable products"],
    "zucchini": ["vegetables and vegetable products"],
    "cilantro": ["spices and herbs"],
    "banana": ["fruits and fruit juices"],
    "apple": ["fruits and fruit juices"],
    "lemon": ["fruits and fruit juices"],
    "lime": ["fruits and fruit juices"],
    "avocado": ["fruits and fruit juices"],
    "rice": ["cereal grains and pasta"],
    "pasta": ["cereal grains and pasta"],
    "oats": ["cereal grains and pasta"],
    "bread": ["baked products"],
    "tortilla": ["baked products", "cereal grains and pasta"],
    "olive oil": ["fats and oils"],
    "sesame oil": ["fats and oils"],
    "soy sauce": ["soups, sauces, and gravies"],
    "coconut milk": ["soups, sauces, and gravies", "beverages"],
    "peanut butter": ["nut and seed products"],
    "honey": ["sweets"],
    "corn": ["vegetables and vegetable products"],
    "frozen peas": ["vegetables and vegetable products"],
}

ALCOHOL_TERMS = ("alcohol", "beer", "wine", "vodka", "rum", "whiskey", "liqueur", "sake", "cocktail")
CONFLICT_TERMS = (
    "imitation",
    "buttermilk",
    "yogurt",
    "candy",
    "candies",
    "flour",
    "sausage",
    "steak",
    "ham",
    "pork",
    "beef",
    "chicken",
    "turkey",
    "lamb",
)


@dataclass
class PantryIngredient:
    ingredient_id: int
    ingredient_key: str
    ingredient_name: str
    calories: float
    protein_g: float
    carbs_g: float
    fat_g: float
    fiber_g: float
    sugar_g: float
    sodium_g: float


def canonical_name(raw: str) -> str:
    return re.sub(r"\s+", " ", raw.replace("_", " ").strip().lower())


def dedupe_keep_order(values: Sequence[str]) -> List[str]:
    out: List[str] = []
    seen: set[str] = set()
    for value in values:
        norm = canonical_name(value)
        if not norm or norm in seen:
            continue
        seen.add(norm)
        out.append(norm)
    return out


def is_probably_numeric(value: str) -> bool:
    return bool(re.fullmatch(r"\d+", value.strip()))


def get_field(item: Any, *keys: str, default: Any = None) -> Any:
    if isinstance(item, dict):
        for key in keys:
            if key in item and item[key] is not None:
                return item[key]
        return default

    for key in keys:
        value = getattr(item, key, None)
        if value is not None:
            return value
    return default


def to_int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def to_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def to_plain(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): to_plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [to_plain(item) for item in value]
    if hasattr(value, "model_dump") and callable(value.model_dump):
        return to_plain(value.model_dump())
    if hasattr(value, "dict") and callable(value.dict):
        return to_plain(value.dict())
    if hasattr(value, "__dict__"):
        return {str(key): to_plain(item) for key, item in vars(value).items() if not key.startswith("_")}
    return str(value)


def chunked(values: Sequence[int], size: int) -> Iterable[List[int]]:
    step = max(1, size)
    for idx in range(0, len(values), step):
        yield list(values[idx : idx + step])


class RequestLimiter:
    def __init__(self, delay_sec: float) -> None:
        self.delay_sec = max(0.0, delay_sec)
        self._lock = threading.Lock()
        self._next_allowed = 0.0

    def wait(self) -> None:
        if self.delay_sec <= 0:
            return
        with self._lock:
            now = time.monotonic()
            if now < self._next_allowed:
                time.sleep(self._next_allowed - now)
                now = time.monotonic()
            self._next_allowed = now + self.delay_sec


class ResponseCache:
    def __init__(self, search: Dict[str, List[Any]] | None = None, foods: Dict[int, Any] | None = None) -> None:
        self._search = search or {}
        self._foods = foods or {}
        self._lock = threading.Lock()

    @classmethod
    def load(cls, path: Path | None) -> "ResponseCache":
        if path is None or not path.exists():
            return cls()
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return cls()

        search = raw.get("search", {})
        foods_raw = raw.get("foods", {})
        foods: Dict[int, Any] = {}
        if isinstance(foods_raw, dict):
            for key, value in foods_raw.items():
                parsed = to_int(key)
                if parsed is not None:
                    foods[parsed] = value

        if not isinstance(search, dict):
            search = {}
        return cls(search=search, foods=foods)

    def save(self, path: Path | None) -> None:
        if path is None:
            return
        with self._lock:
            payload = {
                "version": 1,
                "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "search": self._search,
                "foods": {str(key): value for key, value in self._foods.items()},
            }
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")

    def get_search(self, key: str) -> List[Any] | None:
        with self._lock:
            value = self._search.get(key)
            if value is None:
                return None
            return copy.deepcopy(value)

    def set_search(self, key: str, value: List[Any]) -> None:
        with self._lock:
            self._search[key] = copy.deepcopy(value)

    def get_food(self, fdc_id: int) -> Any | None:
        with self._lock:
            value = self._foods.get(fdc_id)
            if value is None:
                return None
            return copy.deepcopy(value)

    def set_food(self, fdc_id: int, value: Any) -> None:
        with self._lock:
            self._foods[fdc_id] = copy.deepcopy(value)


def parse_ingredients_from_data_json(path: Path) -> List[PantryIngredient]:
    obj = json.loads(path.read_text(encoding="utf-8"))
    raw_map: Dict[str, List[Any]] = obj.get("ingredients", {})

    out: List[PantryIngredient] = []
    for key_str, arr in raw_map.items():
        try:
            ingredient_id = int(key_str)
        except ValueError:
            continue
        if not isinstance(arr, list) or len(arr) < 8:
            continue

        name = str(arr[0])
        out.append(
            PantryIngredient(
                ingredient_id=ingredient_id,
                ingredient_key=key_str,
                ingredient_name=canonical_name(name),
                calories=float(arr[1]),
                protein_g=float(arr[2]),
                carbs_g=float(arr[3]),
                fat_g=float(arr[4]),
                fiber_g=float(arr[5]),
                sugar_g=float(arr[6]),
                sodium_g=float(arr[7]),
            )
        )

    return sorted(out, key=lambda x: x.ingredient_id)


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


def relative_diff(a: float, b: float) -> float:
    denom = max(abs(a), abs(b), 1.0)
    return abs(a - b) / denom


def score_candidate(ingredient: PantryIngredient, query: str, detail_food: Any) -> tuple[float, Dict[str, float]]:
    macros = extract_macros(detail_food)
    description = canonical_name(str(get_field(detail_food, "description", default="") or ""))

    tokens = [t for t in canonical_name(query).split(" ") if t and t not in STOP_WORDS]
    missing_tokens = sum(1 for token in tokens if token not in description)
    token_penalty = 0.75 * missing_tokens

    data_type = canonical_name(str(get_field(detail_food, "dataType", "data_type", default="")))
    data_type_penalty = 0.0
    if "branded" in data_type:
        data_type_penalty += 1.0
    elif "foundation" in data_type:
        data_type_penalty -= 0.1

    macro_distance = (
        3.0 * relative_diff(macros["calories"], ingredient.calories)
        + relative_diff(macros["protein_g"], ingredient.protein_g)
        + relative_diff(macros["carbs_g"], ingredient.carbs_g)
        + relative_diff(macros["fat_g"], ingredient.fat_g)
    )

    score = macro_distance + token_penalty + data_type_penalty
    return score, macros


def post_json(url: str, payload: Dict[str, Any], headers: Dict[str, str]) -> Dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def get_json(url: str, headers: Dict[str, str]) -> Dict[str, Any]:
    request = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


class FDCClientAdapter:
    def __init__(
        self,
        api_key: str,
        cache: ResponseCache | None = None,
        limiter: RequestLimiter | None = None,
    ) -> None:
        self.api_key = api_key
        self.cache = cache or ResponseCache()
        self.limiter = limiter
        self.mode = "http"
        self._client: Any = None
        self._FdcRateLimitError: Any = None
        self._FdcApiError: Any = None
        self._FdcAuthError: Any = None

        if FdcClient is not None:
            self.mode = "usda-fdc"
            self._client = FdcClient(api_key=api_key)
            self._FdcRateLimitError = FdcRateLimitError
            self._FdcApiError = FdcApiError
            self._FdcAuthError = FdcAuthError

    def _search_cache_key(self, query: str, page_size: int, data_types: Sequence[str]) -> str:
        payload = {
            "query": canonical_name(query),
            "page_size": page_size,
            "data_types": [canonical_name(value) for value in data_types],
        }
        return json.dumps(payload, separators=(",", ":"), sort_keys=True)

    def _is_rate_limit(self, exc: Exception) -> bool:
        if self._FdcRateLimitError is not None and isinstance(exc, self._FdcRateLimitError):
            return True
        if isinstance(exc, urllib.error.HTTPError) and exc.code == 429:
            return True
        return "429" in str(exc).lower() or "rate limit" in str(exc).lower()

    def _with_retries(self, op: Callable[[], Any]) -> Any:
        last_error: Exception | None = None
        for attempt in range(3):
            try:
                if self.limiter is not None:
                    self.limiter.wait()
                return op()
            except Exception as exc:
                last_error = exc
                sleep_time = max(1.0, 0.7 * (attempt + 1)) if self._is_rate_limit(exc) else 0.3 * (attempt + 1)
                time.sleep(sleep_time)
        if last_error is not None:
            raise last_error
        return None

    def search(self, query: str, page_size: int, data_types: Sequence[str]) -> List[Any]:
        cache_key = self._search_cache_key(query=query, page_size=page_size, data_types=data_types)
        cached = self.cache.get_search(cache_key)
        if cached is not None:
            return cached

        if self.mode == "usda-fdc":
            result = self._with_retries(
                lambda: self._client.search(
                    query=query,
                    data_type=list(data_types),
                    page_size=page_size,
                    page_number=1,
                    sort_by="fdcId",
                    sort_order="asc",
                )
            )
            foods = to_plain(list(get_field(result, "foods", default=[]) or []))
            self.cache.set_search(cache_key, foods)
            return foods

        headers = {
            "Content-Type": "application/json",
            "User-Agent": "FridgeLuckUSDAIngestion/1.0 (+offline-food-recommendation-app)",
        }
        payload = {
            "query": query,
            "dataType": list(data_types),
            "pageSize": page_size,
            "pageNumber": 1,
            "sortBy": "fdcId",
            "sortOrder": "asc",
        }
        response = self._with_retries(lambda: post_json(f"{FDC_SEARCH_URL}?api_key={self.api_key}", payload, headers))
        foods = to_plain(list(response.get("foods", []) or []))
        self.cache.set_search(cache_key, foods)
        return foods

    def list_foods(
        self,
        page_size: int,
        page_number: int,
        data_types: Sequence[str],
        sort_by: str = "fdcId",
        sort_order: str = "asc",
    ) -> List[Any]:
        cache_key = self._search_cache_key(
            query=f"__list__:{page_number}:{sort_by}:{sort_order}",
            page_size=page_size,
            data_types=data_types,
        )
        cached = self.cache.get_search(cache_key)
        if cached is not None:
            return cached

        if self.mode == "usda-fdc":
            rows = self._with_retries(
                lambda: self._client.list_foods(
                    data_type=list(data_types),
                    page_size=page_size,
                    page_number=page_number,
                    sort_by=sort_by,
                    sort_order=sort_order,
                )
            )
            foods = to_plain(rows)
            self.cache.set_search(cache_key, foods)
            return foods

        params = {
            "api_key": self.api_key,
            "pageSize": page_size,
            "pageNumber": page_number,
            "dataType": list(data_types),
            "sortBy": sort_by,
            "sortOrder": sort_order,
        }
        query = urllib.parse.urlencode(params, doseq=True)
        headers = {"User-Agent": "FridgeLuckUSDAIngestion/1.0 (+offline-food-recommendation-app)"}
        rows = self._with_retries(lambda: get_json(f"{FDC_FOODS_LIST_URL}?{query}", headers))
        foods = to_plain(rows if isinstance(rows, list) else [])
        self.cache.set_search(cache_key, foods)
        return foods

    def get_food(self, fdc_id: int, format: str = "full", nutrients: Sequence[int] | None = None) -> Any:
        cached = self.cache.get_food(fdc_id)
        if cached is not None:
            return cached

        if self.mode == "usda-fdc":
            kwargs: Dict[str, Any] = {"format": format}
            if nutrients:
                kwargs["nutrients"] = list(nutrients)
            detail = self._with_retries(lambda: self._client.get_food(fdc_id, **kwargs))
            normalized = to_plain(detail)
            self.cache.set_food(fdc_id, normalized)
            return normalized

        headers = {
            "User-Agent": "FridgeLuckUSDAIngestion/1.0 (+offline-food-recommendation-app)",
        }
        query_data: Dict[str, Any] = {"api_key": self.api_key, "format": format}
        if nutrients:
            query_data["nutrients"] = list(nutrients)
        query = urllib.parse.urlencode(query_data, doseq=True)
        url = f"{FDC_FOOD_URL}/{fdc_id}?{query}"
        detail = self._with_retries(lambda: get_json(url, headers))
        normalized = to_plain(detail)
        self.cache.set_food(fdc_id, normalized)
        return normalized

    def get_foods(
        self,
        fdc_ids: Sequence[int],
        format: str = "full",
        nutrients: Sequence[int] | None = None,
    ) -> Dict[int, Any]:
        ids = dedupe_keep_order([str(to_int(item)) for item in fdc_ids if to_int(item) is not None])
        normalized_ids = [int(item) for item in ids]
        out: Dict[int, Any] = {}
        missing: List[int] = []
        for fdc_id in normalized_ids:
            cached = self.cache.get_food(fdc_id)
            if cached is not None:
                out[fdc_id] = cached
            else:
                missing.append(fdc_id)

        if not missing:
            return out

        if self.mode == "usda-fdc":
            for chunk in chunked(missing, 20):
                try:
                    kwargs: Dict[str, Any] = {"format": format}
                    if nutrients:
                        kwargs["nutrients"] = list(nutrients)
                    result = self._with_retries(
                        lambda current_chunk=chunk: self._client.get_foods(
                            current_chunk,
                            **kwargs,
                        )
                    )
                except Exception:
                    continue

                rows = to_plain(result)
                for row in rows:
                    row_id = to_int(get_field(row, "fdcId", "fdc_id"))
                    if row_id is None:
                        continue
                    self.cache.set_food(row_id, row)
                    out[row_id] = row

        else:
            headers = {
                "Content-Type": "application/json",
                "User-Agent": "FridgeLuckUSDAIngestion/1.0 (+offline-food-recommendation-app)",
            }
            for chunk in chunked(missing, 20):
                payload: Dict[str, Any] = {"fdcIds": chunk, "format": format}
                if nutrients:
                    payload["nutrients"] = list(nutrients)
                try:
                    rows = self._with_retries(lambda current_payload=payload: post_json(f"{FDC_FOODS_URL}?api_key={self.api_key}", current_payload, headers))
                except Exception:
                    continue
                row_list = rows if isinstance(rows, list) else []
                for row in row_list:
                    row_id = to_int(get_field(row, "fdcId", "fdc_id"))
                    if row_id is None:
                        continue
                    normalized = to_plain(row)
                    self.cache.set_food(row_id, normalized)
                    out[row_id] = normalized

        # Any misses after batch fetch fall back to the single-food endpoint.
        for fdc_id in normalized_ids:
            if fdc_id in out:
                continue
            try:
                out[fdc_id] = self.get_food(fdc_id, format=format, nutrients=nutrients)
            except Exception:
                continue
        return out

    @property
    def source_label(self) -> str:
        if self.mode == "usda-fdc":
            return "USDA FoodData Central API (usda-fdc client)"
        return "USDA FoodData Central API (direct HTTP fallback)"


def build_queries(ingredient: PantryIngredient) -> List[str]:
    normalized_name = canonical_name(ingredient.ingredient_name)
    alias_values = ALIASES.get(normalized_name, []) or ALIASES.get(normalized_name.replace(" ", "_"), [])
    raw_key_name = canonical_name(ingredient.ingredient_key)
    key_query = [] if is_probably_numeric(raw_key_name) else [raw_key_name]
    return dedupe_keep_order([*alias_values, normalized_name, *key_query])


def has_required_tokens(ingredient_name: str, description: str) -> bool:
    ingredient_tokens = [t for t in canonical_name(ingredient_name).split(" ") if t and t not in STOP_WORDS]
    if not ingredient_tokens:
        return True
    matched = sum(1 for token in ingredient_tokens if token in description)
    ratio = matched / len(ingredient_tokens)
    return ratio >= 0.5


def has_conflict_terms(ingredient_name: str, description: str) -> bool:
    ingredient_tokens = set(canonical_name(ingredient_name).split(" "))
    for term in CONFLICT_TERMS:
        if term in description and term not in ingredient_tokens:
            return True
    return False


def summary_score(ingredient: PantryIngredient, description: str, food_category: str, query: str) -> float:
    ingredient_tokens = [t for t in canonical_name(ingredient.ingredient_name).split(" ") if t and t not in STOP_WORDS]
    query_tokens = [t for t in canonical_name(query).split(" ") if t and t not in STOP_WORDS]

    missing_ingredient_tokens = sum(1 for token in ingredient_tokens if token not in description)
    missing_query_tokens = sum(1 for token in query_tokens if token not in description)
    token_penalty = 1.0 * missing_ingredient_tokens + 0.5 * missing_query_tokens

    category_penalty = 0.0
    category_keywords = CATEGORY_HINTS.get(ingredient.ingredient_name, [])
    if category_keywords and not any(keyword in food_category for keyword in category_keywords):
        category_penalty += 1.25

    return token_penalty + category_penalty


def fallback_match(
    ingredient: PantryIngredient,
    query_used: str,
    source: str,
    error: str | None,
) -> Dict[str, Any]:
    return {
        "query_used": query_used,
        "matched_fdc_id": None,
        "matched_description": None,
        "matched_data_type": None,
        "matched_food_category": None,
        "match_score": None,
        "calories": round(ingredient.calories, 4),
        "protein_g": round(ingredient.protein_g, 4),
        "carbs_g": round(ingredient.carbs_g, 4),
        "fat_g": round(ingredient.fat_g, 4),
        "fiber_g": round(ingredient.fiber_g, 4),
        "sugar_g": round(ingredient.sugar_g, 4),
        "sodium_g": round(ingredient.sodium_g, 4),
        "source": source,
        "error": error,
    }


def build_common_food_catalog(
    client: FDCClientAdapter,
    target_size: int,
    max_pages: int,
    page_size: int,
) -> List[Dict[str, Any]]:
    target = max(100, target_size)
    pages = max(1, max_pages)
    rows_per_page = max(1, min(200, page_size))

    summaries: List[Dict[str, Any]] = []
    seen_ids: set[int] = set()

    for page in range(1, pages + 1):
        food_rows = client.list_foods(
            page_size=rows_per_page,
            page_number=page,
            data_types=CATALOG_DATA_TYPES,
            sort_by="fdcId",
            sort_order="asc",
        )
        if not food_rows:
            break

        for row in food_rows:
            fdc_id = to_int(get_field(row, "fdc_id", "fdcId"))
            description = str(get_field(row, "description", default="") or "")
            description_norm = canonical_name(description)
            data_type = str(get_field(row, "dataType", "data_type", default="") or "")
            if not description_norm or fdc_id is None or fdc_id in seen_ids:
                continue
            if "recipe" in description_norm or "prepared" in description_norm:
                continue
            if any(term in description_norm for term in ALCOHOL_TERMS):
                continue
            if any(
                token in description_norm for token in (
                    "restaurant",
                    "fast food",
                    "frozen dinner",
                    "tv dinner",
                    "sandwich",
                    "burger",
                    "pizza",
                    "burrito",
                    "taco",
                    "casserole",
                    "cookie",
                    "cake",
                    "snack",
                    "candy",
                    "soda",
                )
            ):
                continue
            macros = extract_macros(row)
            category_obj = get_field(row, "foodCategory", "food_category", default="")
            if isinstance(category_obj, dict):
                food_category = str(get_field(category_obj, "description", "name", default="") or "")
            else:
                food_category = str(category_obj or "")
            seen_ids.add(fdc_id)
            summaries.append(
                {
                    "fdc_id": fdc_id,
                    "description": description,
                    "description_norm": description_norm,
                    "data_type": data_type,
                    "food_category": food_category,
                    "food_code": str(get_field(row, "foodCode", "food_code", default="") or ""),
                    "food_class": str(get_field(row, "foodClass", "food_class", default="") or ""),
                    "brand_owner": str(get_field(row, "brandOwner", "brand_owner", default="") or ""),
                    "brand_name": str(get_field(row, "brandName", "brand_name", default="") or ""),
                    "ingredients_text": str(get_field(row, "ingredients", default="") or ""),
                    **macros,
                }
            )
            if len(summaries) >= target:
                break
        if len(summaries) >= target:
            break

    if not summaries:
        return []

    detail_needed: List[int] = []
    for row in summaries:
        macro_signal = (
            float(row.get("calories", 0.0) or 0.0)
            + float(row.get("protein_g", 0.0) or 0.0)
            + float(row.get("carbs_g", 0.0) or 0.0)
            + float(row.get("fat_g", 0.0) or 0.0)
            + float(row.get("fiber_g", 0.0) or 0.0)
            + float(row.get("sugar_g", 0.0) or 0.0)
            + float(row.get("sodium_g", 0.0) or 0.0)
        )
        food_category_obj = get_field(row, "foodCategory", "food_category", default="")
        has_category = False
        if isinstance(food_category_obj, dict):
            has_category = bool(get_field(food_category_obj, "description", "name", default=""))
        else:
            has_category = bool(str(food_category_obj or "").strip())
        if macro_signal <= 0.0 or not has_category:
            detail_needed.append(int(row["fdc_id"]))

    detail_map = client.get_foods(detail_needed, format="full") if detail_needed else {}
    catalog: List[Dict[str, Any]] = []
    for summary in summaries:
        fdc_id = summary["fdc_id"]
        detail = detail_map.get(fdc_id) or summary
        category_obj = get_field(detail, "foodCategory", "food_category", default="")
        if isinstance(category_obj, dict):
            food_category = str(get_field(category_obj, "description", "name", default="") or "")
        else:
            food_category = str(category_obj or "")

        macros = extract_macros(detail)
        macro_signal = (
            macros["calories"]
            + macros["protein_g"]
            + macros["carbs_g"]
            + macros["fat_g"]
            + macros["fiber_g"]
            + macros["sugar_g"]
            + macros["sodium_g"]
        )
        if macro_signal <= 0.0:
            macros = {
                "calories": round(float(summary.get("calories", 0.0) or 0.0), 4),
                "protein_g": round(float(summary.get("protein_g", 0.0) or 0.0), 4),
                "carbs_g": round(float(summary.get("carbs_g", 0.0) or 0.0), 4),
                "fat_g": round(float(summary.get("fat_g", 0.0) or 0.0), 4),
                "fiber_g": round(float(summary.get("fiber_g", 0.0) or 0.0), 4),
                "sugar_g": round(float(summary.get("sugar_g", 0.0) or 0.0), 4),
                "sodium_g": round(float(summary.get("sodium_g", 0.0) or 0.0), 4),
            }
        catalog.append(
            {
                "fdc_id": fdc_id,
                "description": str(get_field(detail, "description", default=summary["description"]) or summary["description"]),
                "description_norm": canonical_name(
                    str(get_field(detail, "description", default=summary["description"]) or summary["description"])
                ),
                "data_type": str(get_field(detail, "dataType", "data_type", default=summary["data_type"]) or summary["data_type"]),
                "food_category": food_category,
                "food_code": summary["food_code"],
                "food_class": str(get_field(detail, "foodClass", "food_class", default=summary.get("food_class", "")) or ""),
                "brand_owner": str(get_field(detail, "brandOwner", "brand_owner", default=summary.get("brand_owner", "")) or ""),
                "brand_name": str(get_field(detail, "brandName", "brand_name", default=summary.get("brand_name", "")) or ""),
                "ingredients_text": str(get_field(detail, "ingredients", default=summary.get("ingredients_text", "")) or ""),
                **macros,
            }
        )

    return catalog


def load_catalog(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    records = obj.get("records", [])
    if not isinstance(records, list):
        return []

    sodium_unit = canonical_name(str(obj.get("sodium_unit", "") or ""))
    sodium_values: List[float] = []
    for row in records:
        if not isinstance(row, dict):
            continue
        sodium = to_float(row.get("sodium_g"))
        if sodium is not None:
            sodium_values.append(float(sodium))
    sodium_scale = 1.0
    if sodium_unit == "mg":
        sodium_scale = 0.001
    elif not sodium_unit and sodium_values:
        sorted_sodium = sorted(sodium_values)
        median_sodium = sorted_sodium[len(sorted_sodium) // 2]
        if median_sodium > 5.0:
            sodium_scale = 0.001

    out: List[Dict[str, Any]] = []
    for row in records:
        if not isinstance(row, dict):
            continue
        fdc_id = to_int(row.get("fdc_id"))
        description = str(row.get("description", "") or "")
        if fdc_id is None or not description:
            continue
        out.append(
            {
                "fdc_id": fdc_id,
                "description": description,
                "description_norm": canonical_name(str(row.get("description_norm", description) or description)),
                "data_type": str(row.get("data_type", "") or ""),
                "food_category": str(row.get("food_category", "") or ""),
                "food_code": str(row.get("food_code", "") or ""),
                "food_class": str(row.get("food_class", "") or ""),
                "brand_owner": str(row.get("brand_owner", "") or ""),
                "brand_name": str(row.get("brand_name", "") or ""),
                "ingredients_text": str(row.get("ingredients_text", "") or ""),
                "calories": round(float(row.get("calories", 0.0) or 0.0), 4),
                "protein_g": round(float(row.get("protein_g", 0.0) or 0.0), 4),
                "carbs_g": round(float(row.get("carbs_g", 0.0) or 0.0), 4),
                "fat_g": round(float(row.get("fat_g", 0.0) or 0.0), 4),
                "fiber_g": round(float(row.get("fiber_g", 0.0) or 0.0), 4),
                "sugar_g": round(float(row.get("sugar_g", 0.0) or 0.0), 4),
                "sodium_g": round(float(row.get("sodium_g", 0.0) or 0.0) * sodium_scale, 4),
            }
        )
    return out


def save_catalog(path: Path, records: List[Dict[str, Any]]) -> None:
    payload = {
        "source": "USDA FoodData Central API catalog bootstrap",
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "record_count": len(records),
        "sodium_unit": "g",
        "records": records,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def match_from_catalog(ingredient: PantryIngredient, catalog: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    ingredient_tokens = {
        token
        for query in build_queries(ingredient)
        for token in canonical_name(query).split(" ")
        if token and token not in STOP_WORDS
    }
    if not ingredient_tokens:
        ingredient_tokens = {token for token in canonical_name(ingredient.ingredient_name).split(" ") if token}

    best: Dict[str, Any] | None = None
    for row in catalog:
        description = str(row.get("description_norm") or row.get("description") or "")
        if not description:
            continue
        token_hits = sum(1 for token in ingredient_tokens if token in description)
        if token_hits <= 0:
            continue

        missing = max(0, len(ingredient_tokens) - token_hits)
        token_penalty = 0.85 * missing - 0.1 * token_hits
        category_penalty = 0.0
        category = canonical_name(str(row.get("food_category", "") or ""))
        category_keywords = CATEGORY_HINTS.get(ingredient.ingredient_name, [])
        if category_keywords and category and not any(keyword in category for keyword in category_keywords):
            category_penalty += 0.9

        data_type = canonical_name(str(row.get("data_type", "") or ""))
        data_type_penalty = 0.0
        if "branded" in data_type:
            data_type_penalty += 0.9
        elif "foundation" in data_type:
            data_type_penalty -= 0.15

        macro_distance = (
            3.0 * relative_diff(float(row.get("calories", 0.0) or 0.0), ingredient.calories)
            + relative_diff(float(row.get("protein_g", 0.0) or 0.0), ingredient.protein_g)
            + relative_diff(float(row.get("carbs_g", 0.0) or 0.0), ingredient.carbs_g)
            + relative_diff(float(row.get("fat_g", 0.0) or 0.0), ingredient.fat_g)
        )
        score = macro_distance + token_penalty + data_type_penalty + category_penalty

        candidate = {
            "query_used": ingredient.ingredient_name,
            "matched_fdc_id": row["fdc_id"],
            "matched_description": str(row.get("description") or ""),
            "matched_data_type": str(row.get("data_type") or ""),
            "matched_food_category": str(row.get("food_category") or ""),
            "match_score": round(score, 4),
            "calories": round(float(row.get("calories", 0.0) or 0.0), 4),
            "protein_g": round(float(row.get("protein_g", 0.0) or 0.0), 4),
            "carbs_g": round(float(row.get("carbs_g", 0.0) or 0.0), 4),
            "fat_g": round(float(row.get("fat_g", 0.0) or 0.0), 4),
            "fiber_g": round(float(row.get("fiber_g", 0.0) or 0.0), 4),
            "sugar_g": round(float(row.get("sugar_g", 0.0) or 0.0), 4),
            "sodium_g": round(float(row.get("sodium_g", 0.0) or 0.0), 4),
        }
        if best is None or candidate["match_score"] < best["match_score"]:
            best = candidate

    if best is None:
        return fallback_match(
            ingredient=ingredient,
            query_used=ingredient.ingredient_name,
            source="Local bundled data fallback",
            error="no USDA catalog candidate",
        )
    if best["match_score"] is None or best["match_score"] > 7.0 or best["calories"] <= 0:
        return fallback_match(
            ingredient=ingredient,
            query_used=ingredient.ingredient_name,
            source="Local bundled data fallback",
            error="USDA catalog match below quality threshold",
        )

    best["source"] = "USDA FoodData Central API (catalog bootstrap)"
    best["error"] = None
    return best


def fetch_best_match(
    ingredient: PantryIngredient,
    client: FDCClientAdapter,
    max_candidates: int,
) -> Dict[str, Any]:
    queries = build_queries(ingredient)
    best: Dict[str, Any] | None = None
    last_error: str | None = None

    detail_fetch_count = 0
    max_detail_fetches = 9
    max_summary_details = 3

    for data_types in SEARCH_DATA_TYPE_PASSES:
        for query in queries:
            try:
                search_rows = client.search(query=query, page_size=max_candidates, data_types=data_types)
            except Exception as exc:
                last_error = str(exc)
                continue

            filtered_summaries: List[tuple[float, Any]] = []
            for summary in search_rows:
                description = canonical_name(str(get_field(summary, "description", default="") or ""))
                fdc_id = to_int(get_field(summary, "fdc_id", "fdcId"))
                food_category = canonical_name(str(get_field(summary, "foodCategory", "food_category", default="") or ""))
                if not description or fdc_id is None:
                    continue
                if "recipe" in description or "prepared" in description or "restaurant foods" in food_category:
                    continue
                if any(term in description for term in ALCOHOL_TERMS):
                    continue
                if not has_required_tokens(ingredient.ingredient_name, description):
                    continue
                if has_conflict_terms(ingredient.ingredient_name, description):
                    continue

                filtered_summaries.append((summary_score(ingredient, description, food_category, query), summary))

            filtered_summaries.sort(key=lambda item: item[0])

            remaining_fetches = max(0, max_detail_fetches - detail_fetch_count)
            if remaining_fetches == 0:
                break
            selected = filtered_summaries[: min(max_summary_details, remaining_fetches)]
            selected_ids = [
                fdc_id
                for _, summary in selected
                if (fdc_id := to_int(get_field(summary, "fdc_id", "fdcId"))) is not None
            ]
            try:
                detail_map = client.get_foods(selected_ids, format="abridged") if selected_ids else {}
            except Exception as exc:
                last_error = str(exc)
                continue

            for _, summary in selected:
                fdc_id = to_int(get_field(summary, "fdc_id", "fdcId"))
                if fdc_id is None:
                    continue
                detail = detail_map.get(fdc_id)
                if detail is None:
                    if last_error is None:
                        last_error = f"missing detail for FDC id {fdc_id}"
                    continue
                detail_fetch_count += 1

                score, macros = score_candidate(ingredient, query, detail)
                category_keywords = CATEGORY_HINTS.get(ingredient.ingredient_name, [])
                detail_category = canonical_name(str(get_field(summary, "foodCategory", "food_category", default="") or ""))
                if category_keywords and not any(keyword in detail_category for keyword in category_keywords):
                    score += 1.25

                candidate = {
                    "query_used": query,
                    "matched_fdc_id": fdc_id,
                    "matched_description": str(get_field(detail, "description", default="") or ""),
                    "matched_data_type": str(get_field(detail, "dataType", "data_type", default="") or ""),
                    "matched_food_category": str(get_field(summary, "foodCategory", "food_category", default="") or ""),
                    "match_score": round(score, 4),
                    **macros,
                }

                if best is None or candidate["match_score"] < best["match_score"]:
                    best = candidate

            # Strong early-exit when we already have a very high-quality match.
            if best is not None and best["match_score"] <= 0.55 and best["calories"] > 0:
                break

        # Foundation-first strategy: only use fallback passes when no acceptable foundation match exists.
        if best is not None:
            break

    if best is None:
        return fallback_match(
            ingredient=ingredient,
            query_used=queries[0] if queries else ingredient.ingredient_name,
            source="Local bundled data fallback",
            error=last_error,
        )

    if best["match_score"] is None or best["match_score"] > 7.0 or best["calories"] <= 0:
        return fallback_match(
            ingredient=ingredient,
            query_used=str(best["query_used"]),
            source="Local bundled data fallback",
            error="USDA match below quality threshold",
        )

    best["source"] = client.source_label
    best["error"] = None
    return best


def run(
    api_key: str | None,
    in_data: Path,
    out: Path,
    ingredient_limit: int | None,
    max_candidates: int,
    delay_sec: float,
    parallelism: int,
    cache_file: Path | None,
    catalog_file: Path,
    catalog_target: int,
    catalog_page_size: int,
    catalog_max_pages: int,
    catalog_refresh: bool,
) -> int:
    ingredients = parse_ingredients_from_data_json(in_data)
    if ingredient_limit is not None and ingredient_limit > 0:
        ingredients = ingredients[:ingredient_limit]

    total = len(ingredients)

    if not api_key:
        records: List[Dict[str, Any]] = []
        for index, ingredient in enumerate(ingredients, start=1):
            match = fallback_match(
                ingredient=ingredient,
                query_used=ingredient.ingredient_name,
                source="Local bundled data fallback (no API key)",
                error="USDA_FDC_API_KEY not set",
            )
            records.append(
                {
                    "ingredient_id": ingredient.ingredient_id,
                    "ingredient_key": ingredient.ingredient_key,
                    "ingredient_name": ingredient.ingredient_name,
                    **match,
                }
            )
            print(f"[{index}/{total}] {ingredient.ingredient_name}: FALLBACK", flush=True)

        payload = {
            "source": "Local bundled data fallback (no API key)",
            "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "ingredient_count": len(records),
            "matched_count": 0,
            "records": records,
        }
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"Wrote {len(records)} ingredient records to {out} (matched 0)")
        return 0

    shared_cache = ResponseCache.load(cache_file)
    limiter = RequestLimiter(delay_sec)
    bootstrap_client = FDCClientAdapter(api_key=api_key, cache=shared_cache, limiter=limiter)

    catalog = [] if catalog_refresh else load_catalog(catalog_file)
    if len(catalog) < max(100, catalog_target):
        catalog = build_common_food_catalog(
            client=bootstrap_client,
            target_size=catalog_target,
            max_pages=catalog_max_pages,
            page_size=catalog_page_size,
        )
        save_catalog(catalog_file, catalog)
        print(f"Built USDA catalog with {len(catalog)} records at {catalog_file}", flush=True)
    else:
        print(f"Loaded USDA catalog with {len(catalog)} records from {catalog_file}", flush=True)

    max_workers = max(1, parallelism)
    if total <= 1:
        max_workers = 1
    worker_local = threading.local()

    def get_worker_client() -> FDCClientAdapter:
        worker_client = getattr(worker_local, "client", None)
        if worker_client is None:
            worker_client = FDCClientAdapter(api_key=api_key, cache=shared_cache, limiter=limiter)
            setattr(worker_local, "client", worker_client)
        return worker_client

    def process_item(index: int, ingredient: PantryIngredient) -> tuple[int, PantryIngredient, Dict[str, Any]]:
        try:
            match = match_from_catalog(ingredient=ingredient, catalog=catalog)
            if match["matched_fdc_id"] is None:
                match = fetch_best_match(
                    ingredient=ingredient,
                    client=get_worker_client(),
                    max_candidates=max_candidates,
                )
        except Exception as exc:
            match = fallback_match(
                ingredient=ingredient,
                query_used=ingredient.ingredient_name,
                source="Local bundled data fallback",
                error=f"unexpected fetch error: {exc}",
            )
        return index, ingredient, match

    results: List[tuple[PantryIngredient, Dict[str, Any]] | None] = [None] * total

    if max_workers == 1:
        for index, ingredient in enumerate(ingredients, start=1):
            _, ing, match = process_item(index, ingredient)
            results[index - 1] = (ing, match)
            status = "MATCH" if match["matched_fdc_id"] is not None else "FALLBACK"
            print(f"[{index}/{total}] {ing.ingredient_name}: {status}", flush=True)
    else:
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = [executor.submit(process_item, idx, ingredient) for idx, ingredient in enumerate(ingredients, start=1)]
            completed = 0
            for future in as_completed(futures):
                index, ing, match = future.result()
                results[index - 1] = (ing, match)
                completed += 1
                status = "MATCH" if match["matched_fdc_id"] is not None else "FALLBACK"
                print(f"[{completed}/{total}] {ing.ingredient_name}: {status}", flush=True)

    records = []
    matched_count = 0
    for item in results:
        if item is None:
            continue
        ingredient, match = item
        if match["matched_fdc_id"] is not None:
            matched_count += 1
        records.append(
            {
                "ingredient_id": ingredient.ingredient_id,
                "ingredient_key": ingredient.ingredient_key,
                "ingredient_name": ingredient.ingredient_name,
                **match,
            }
        )

    source = "USDA FoodData Central API (catalog bootstrap + targeted fallback)"
    payload = {
        "source": source,
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "ingredient_count": len(records),
        "matched_count": matched_count,
        "catalog_record_count": len(catalog),
        "catalog_file": str(catalog_file),
        "records": records,
    }

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    shared_cache.save(cache_file)
    if cache_file is not None:
        print(f"Saved USDA response cache to {cache_file}")
    print(f"Wrote {len(records)} ingredient records to {out} (matched {matched_count})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect USDA nutrition data for app ingredients.")
    parser.add_argument("--api-key", default=os.getenv("USDA_FDC_API_KEY"), help="USDA API key (or USDA_FDC_API_KEY env var)")
    parser.add_argument("--in-data", type=Path, default=DEFAULT_INPUT, help="Input bundled data.json path")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT, help="Output compact JSON path")
    parser.add_argument("--ingredient-limit", type=int, default=None, help="Optional ingredient count limit")
    parser.add_argument("--max-candidates", type=int, default=10, help="Max search candidates per ingredient query")
    parser.add_argument("--delay-sec", type=float, default=0.15, help="Minimum delay between outbound USDA API requests")
    parser.add_argument("--parallelism", type=int, default=6, help="Concurrent ingredient workers")
    parser.add_argument(
        "--cache-file",
        type=Path,
        default=Path("scripts/data/.cache/usda_fdc_response_cache.json"),
        help="Persistent USDA API response cache path",
    )
    parser.add_argument(
        "--catalog-file",
        type=Path,
        default=DEFAULT_CATALOG,
        help="Common USDA food catalog cache path",
    )
    parser.add_argument("--catalog-target", type=int, default=5000, help="Target number of common USDA catalog rows to bootstrap")
    parser.add_argument("--catalog-page-size", type=int, default=200, help="USDA foods/list page size (1-200)")
    parser.add_argument("--catalog-max-pages", type=int, default=25, help="Maximum USDA foods/list pages to scan for catalog bootstrap")
    parser.add_argument("--catalog-refresh", action="store_true", help="Force refresh USDA catalog instead of reusing cached catalog file")
    args = parser.parse_args()

    try:
        return run(
            api_key=args.api_key,
            in_data=args.in_data,
            out=args.out,
            ingredient_limit=args.ingredient_limit,
            max_candidates=args.max_candidates,
            delay_sec=args.delay_sec,
            parallelism=args.parallelism,
            cache_file=args.cache_file,
            catalog_file=args.catalog_file,
            catalog_target=args.catalog_target,
            catalog_page_size=args.catalog_page_size,
            catalog_max_pages=args.catalog_max_pages,
            catalog_refresh=args.catalog_refresh,
        )
    except urllib.error.HTTPError as exc:
        print(f"HTTP error while collecting USDA data: {exc.code} {exc.reason}")
        return 1
    except urllib.error.URLError as exc:
        print(f"Network error while collecting USDA data: {exc.reason}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
