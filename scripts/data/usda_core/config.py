from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DATA_DIR = ROOT / "scripts" / "data"
CACHE_DIR = DATA_DIR / ".cache"
CATALOG_DIR = DATA_DIR / "catalog"
REVIEW_BATCH_DIR = DATA_DIR / "review_batches"
CANDIDATE_DIR = CACHE_DIR / "candidates"

CANONICAL_JSON = CATALOG_DIR / "usda_curated_ingredients.json"
CACHE_DB = CACHE_DIR / "usda_http_cache.sqlite"
DEFAULT_SQLITE_OUT = ROOT / "FridgeLuck.swiftpm" / "Resources" / "usda_ingredient_catalog.sqlite"
DEFAULT_REPORT_OUT = CACHE_DIR / "usda_pipeline_report.md"

USDA_SEARCH_URL = "https://api.nal.usda.gov/fdc/v1/foods/search"
USDA_FOOD_URL = "https://api.nal.usda.gov/fdc/v1/food"
USDA_FOODS_URL = "https://api.nal.usda.gov/fdc/v1/foods"

USDA_USER_AGENT = "FridgeLuckUSDAPipeline/2.0 (+offline-food-recommendation-app)"

DEFAULT_REQUIRED_TERMS = [
    "all-purpose flour",
    "canned tuna",
    "olive oil",
    "black beans",
    "frozen peas",
    "2% milk",
    "1% milk",
    "skim milk",
    "whole milk",
    "black pepper",
    "red pepper flakes",
    "green onion",
    "scallion",
    "rotisserie chicken",
]

CATEGORY_TO_SPRITE_GROUP = {
    "protein": "protein",
    "vegetable": "vegetable",
    "fruit": "fruit",
    "grain_legume": "grain_legume",
    "dairy_egg": "dairy_egg",
    "oil_fat": "oil_fat",
    "herb_spice": "herb_spice",
    "nut_seed": "nut_seed",
    "condiment": "condiment",
    "fungi": "fungi",
    "sweetener_baking": "sweetener",
    "other": "other",
}

DISTINCT_SPRITE_KEYS = {
    "celery": "celery",
    "lettuce": "lettuce",
    "spinach": "spinach",
    "broccoli": "broccoli",
    "carrot": "carrot",
    "onion": "onion",
    "green onion": "green_onion",
    "scallion": "green_onion",
    "bell pepper": "bell_pepper",
    "tomato": "tomato",
    "cucumber": "cucumber",
    "zucchini": "zucchini",
    "garlic": "garlic",
    "avocado": "avocado",
    "potato": "potato",
}

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
