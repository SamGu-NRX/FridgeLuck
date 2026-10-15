#!/usr/bin/env python3
"""Build the canonical ingredient vocabulary from the corpus, legacy catalog,
bundled USDA catalog, and full FoodData Central bulk CSVs (CC0).

Run once per vocabulary revision; the committed outputs under data/ingredients/
are what compile_bundle.py consumes (the compiler never re-derives identity).

Inputs:
  data/recipes/corpus.jsonl                          RS v1 corpus (surface names, unit evidence)
  apps/ios/Resources/data.json                       legacy 50 ingredients
  apps/ios/Resources/usda_ingredient_catalog.sqlite  bundled 800-row USDA catalog
  /tmp/canon/identities.json, /tmp/canon/facts.json  ingredient-facts canon (branch eval/scorecard-runner, read-only)
  /tmp/fdc/.../food.csv, food_nutrient.csv           USDA FoodData Central bulk CSVs (survey FNDDS 2024-10-31, SR Legacy 2018-04), CC0

Outputs (committed):
  data/ingredients/vocabulary.json       canonical entries (key -> identity, nutrition, classes, aliases, unit weights)
  data/ingredients/name-mappings.json    every corpus/legacy surface name -> canonical key
  data/ingredients/fdc-new-rows.json     audit trail of FDC rows added beyond the bundled 800
  data/recipes/legacy-ingredient-map.json  50-entry identity map (ingredient-identity.schema.json)

Deterministic: every iteration over data is sorted; same inputs -> byte-identical outputs.
"""

from __future__ import annotations

import csv
import json
import re
import sqlite3
import statistics
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pipeline.normalize import normalize_name, slugify, singular, strip_prep  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
ING_DIR = REPO / "data" / "ingredients"
FDC_DIRS = {
    "survey_fndds_food": Path("/tmp/fdc/FoodData_Central_survey_food_csv_2024-10-31"),
    "sr_legacy_food": Path("/tmp/fdc/FoodData_Central_sr_legacy_food_csv_2018-04"),
}

# Curated decisions: surface name (normalized) -> canonical key, where automatic
# rules would pick wrong or the corpus evidence merges foods. Every entry carries
# a reason; the audit trail ships in name-mappings.json.
KEY_OVERRIDES: dict[str, tuple[str, str]] = {
    # pasta shapes are one food identity: dried wheat pasta
    "spaghetti": ("pasta_dried", "pasta shapes share one identity"),
    "linguine": ("pasta_dried", "pasta shapes share one identity"),
    "penne": ("pasta_dried", "pasta shapes share one identity"),
    "rigatoni": ("pasta_dried", "pasta shapes share one identity"),
    "orecchiette": ("pasta_dried", "pasta shapes share one identity"),
    "pappardelle": ("pasta_dried", "pasta shapes share one identity"),
    "tagliatelle": ("pasta_dried", "pasta shapes share one identity"),
    "ditalini": ("pasta_dried", "pasta shapes share one identity"),
    "casarecce": ("pasta_dried", "pasta shapes share one identity"),
    "small pasta shells": ("pasta_dried", "pasta shapes share one identity"),
    "dried pasta": ("pasta_dried", "pasta shapes share one identity"),
    "dry pasta": ("pasta_dried", "pasta shapes share one identity"),
    "pappardelle or other wide pasta": ("pasta_dried", "first alternative names the identity"),
    # rice: variety names collapse to white rice (nutrition identical; pantry fit wants one key)
    "basmati rice": ("white_rice", "variety of white rice"),
    "jasmine rice": ("white_rice", "variety of white rice"),
    "long grain rice": ("white_rice", "variety of white rice"),
    "risotto rice": ("white_rice", "variety of white rice"),
    "cooked basmati rice": ("cooked_rice", "variety of cooked white rice"),
    # lentils / beans
    "black beluga lentils": ("lentils", "black lentils hold shape; same food identity for pantry fit"),
    "cooked yellow lentils": ("cooked_lentils", "cooked lentils, color is variety"),
    "dried navy beans": ("white_beans", "navy beans are the classic white bean"),
    "cannellini beans": ("white_beans", "cannellini are white beans"),
    "red kidney beans": ("kidney_beans", "kidney beans, color is variety"),
    # fish / seafood
    "thick white fish fillets": ("white_fish", "generic white fish, FNDDS Fish NFS row"),
    "white fish fillets": ("white_fish", "generic white fish, FNDDS Fish NFS row"),
    "raw prawns": ("shrimp", "prawns and shrimp are one identity (FDC Shrimp)"),
    "white crab meat": ("crab_meat", "picked white crab meat"),
    # meats
    "beef chuck roast": ("beef_chuck", "specific cut, distinct identity"),
    "pork shoulder roast": ("pork_shoulder", "specific cut, distinct identity"),
    "good sausages": ("sausages", "generic sausage identity"),
    "salt pork": ("salt_pork", "cured pork, distinct identity"),
    # dairy
    "whole milk ricotta": ("ricotta", "ricotta is whole-milk by default here"),
    "ghee or vegetable oil": ("ghee", "first alternative names the primary identity"),
    # vegetables / fruit
    "aubergines": ("eggplant", "british name for eggplant"),
    "small eggplant": ("eggplant", "size is not identity"),
    "cavolo nero": ("kale", "lacinato kale, one identity for pantry fit"),
    "little gem lettuce": ("lettuce", "little gem is a romaine-type lettuce"),
    "romaine lettuce": ("lettuce", "romaine is a lettuce"),
    "lettuce leaves": ("lettuce", "the leaf is the food"),
    "nicoise olives": ("olives", "cured olive, one identity for pantry fit"),
    "green olives": ("olives", "cured olive, one identity for pantry fit"),
    "dill pickles": ("pickles", "dill is the style"),
    "bell peppers": ("bell_pepper", "singular form of the legacy identity"),
    "green bell pepper": ("bell_pepper", "color is ripeness, one identity"),
    "red bell pepper": ("bell_pepper", "color is ripeness, one identity"),
    "red bell peppers": ("bell_pepper", "color is ripeness, one identity"),
    "chili flakes": ("red_pepper_flakes", "matches the legacy identity"),
    "cayenne or chili flakes": ("red_pepper_flakes", "first alternative names the identity"),
    "green chili": ("green_chili", "fresh green chili, distinct from flakes"),
    "mild green chiles": ("green_chili", "mild green chiles, same identity"),
    "chili powder": ("chili_powder", "spice blend, distinct from flakes"),
    "corn kernels": ("corn", "the kernels are the food (legacy corn)"),
    "green peas": ("frozen_peas", "corpus uses peas from frozen; legacy identity frozen_peas"),
    "frozen peas": ("frozen_peas", "legacy identity"),
    "scallions": ("green_onion", "same identity as legacy green_onion"),
    "green onions": ("green_onion", "legacy identity"),
    "red cabbage": ("red_cabbage", "distinct identity from green cabbage"),
    "white cabbage": ("cabbage", "green cabbage is the default identity"),
    "shredded cabbage": ("cabbage", "prep is not identity"),
    "cabbage leaves": ("cabbage", "the leaf is the food"),
    "sweet potatoes": ("sweet_potato", "legacy identity"),
    "russet potatoes": ("potato", "baking potato, legacy potato identity"),
    "baking potatoes": ("potato", "baking potato, legacy potato identity"),
    "new potatoes": ("potato", "young potato, legacy potato identity"),
    "baby spinach": ("spinach", "prep state is not identity (legacy spinach)"),
    "cherry tomatoes": ("cherry_tomato", "distinct eating identity from slicing tomato"),
    "ripe tomatoes": ("tomato", "ripeness is not identity"),
    "canned tomatoes": ("canned_tomatoes", "one canned-tomato identity"),
    "canned chopped tomatoes": ("canned_tomatoes", "one canned-tomato identity"),
    "canned crushed tomatoes": ("canned_tomatoes", "one canned-tomato identity"),
    "canned whole tomatoes": ("canned_tomatoes", "one canned-tomato identity"),
    "jarred roasted red peppers": ("roasted_red_peppers", "distinct prepared identity"),
    # pantry / condiments
    "plain flour": ("all_purpose_flour", "plain flour is all-purpose flour (canon key)"),
    "whole wheat flour": ("whole_wheat_flour", "distinct flour identity"),
    "brown sugar": ("brown_sugar", "distinct sugar identity"),
    "dijon mustard": ("mustard", "mustard identity for pantry fit"),
    "wholegrain mustard": ("mustard", "mustard identity for pantry fit"),
    "white miso": ("miso", "miso identity for pantry fit"),
    "tamarind paste or rice vinegar": ("tamarind_paste", "first alternative names the identity"),
    "espresso or strong coffee": ("coffee", "brewed coffee identity"),
    "black tea bag": ("black_tea", "tea bag identity"),
    "cola": ("cola", "beverage identity"),
    "apple cider": ("apple_cider", "beverage identity"),
    "unsweetened cocoa powder": ("cocoa_powder", "cocoa identity"),
    "chipotle in adobo": ("chipotle", "chipotle identity for pantry fit"),
    "chipotle paste": ("chipotle", "chipotle identity for pantry fit"),
    "tortilla chips": ("tortilla_chips", "distinct identity from tortillas"),
    "corn tortillas": ("corn_tortillas", "distinct identity from flour tortillas"),
    "tortillas": ("tortillas", "flour tortilla default (legacy tortilla)"),
    "small flour tortillas": ("tortillas", "size is not identity"),
    "pita breads": ("pita", "plural of canon pita"),
    "burger buns": ("burger_buns", "distinct bread identity"),
    "crusty bread": ("bread", "legacy bread identity"),
    "sourdough bread": ("bread", "legacy bread identity"),
    "thick cut bread": ("bread", "prep is not identity"),
    "day old bread": ("bread", "prep is not identity"),
    "stale bread": ("bread", "prep is not identity"),
    # misc
    "a handful of mint leaves": ("mint", "quantity phrase is not identity"),
    "a large bunch of parsley and mint": ("parsley", "first alternative names the identity"),
    "mint leaves": ("mint", "the leaf is the food"),
    "basil leaves": ("basil", "the leaf is the food"),
    "flattened rice poha": ("flattened_rice", "distinct grain identity"),
    "beansprouts": ("beansprouts", "distinct identity"),
    "pearled farro": ("farro", "farro identity"),
    "giant couscous": ("couscous", "canon couscous identity"),
    "pearl couscous": ("couscous", "canon couscous identity"),
    "medium couscous": ("couscous", "canon couscous identity"),
    "dry couscous": ("couscous", "canon couscous identity"),
    "ready hummus": ("hummus", "prepared hummus identity"),
    "jerk seasoning paste": ("jerk_seasoning", "spice blend identity"),
    "ras el hanout": ("ras_el_hanout", "spice blend identity"),
    "shelf stable gnocchi": ("gnocchi", "gnocchi identity"),
    "ready rolled puff pastry": ("puff_pastry", "pastry identity"),
    "preserved lemon": ("preserved_lemon", "distinct identity from lemon"),
    "toasted sesame oil": ("sesame_oil", "legacy identity; toasting is prep"),
    "toasted sesame seeds": ("sesame_seeds", "prep is not identity"),
    "vegetable oil": ("vegetable_oil", "distinct oil identity"),
    "coconut oil": ("coconut_oil", "distinct oil identity"),
    "maple syrup": ("maple_syrup", "distinct sweetener identity"),
    "mint oregano": ("mint", "first alternative names the identity"),
    "pitta": ("pita", "spelling variant of pita"),
    "sardines in oil": ("sardines", "oil-packed is the default canned sardine"),
    "tuna in oil": ("canned_tuna", "oil-packed is the default canned tuna"),
    "flat leaf parsley": ("parsley", "flat-leaf is regular parsley"),
    "cherry tomatoes": ("tomato", "small variety, one tomato identity; FNDDS has no cherry row"),
}

# Hand-verified USDA rows for keys whose automatic resolution picks a wrong or
# unrepresentative row. Each pin was checked against the FDC description.
FDC_PINS: dict[str, tuple[int, str]] = {
    "milk": (171265, "Milk, whole, 3.25% milkfat (SR Legacy) - catalog subset lacks whole milk"),
    "crab_meat": (171966, "Crustaceans, crab, blue, canned (SR Legacy) - matches picked white crab meat"),
    "shrimp": (174210, "Crustaceans, shrimp, mixed species, raw (SR Legacy)"),
    "ghee": (173412, "Butter oil, anhydrous (SR Legacy) - ghee is clarified butterfat"),
    "pita": (2707616, "Bread, pita (FNDDS) - tail reject would hide the Pita bread row"),
    "paneer": (2705740, "Cheese, paneer (FNDDS)"),
    "molasses": (168820, "Molasses (SR Legacy)"),
    "wheat_noodles": (169731, "Noodles, egg, dry, enriched (SR Legacy) - closest dry wheat noodle"),
    "ramen_noodles": (169731, "Noodles, egg, dry, enriched (SR Legacy) - closest dry wheat noodle"),
    "smoked_paprika": (171329, "Spices, paprika (SR Legacy)"),
    "oregano": (171328, "Spices, oregano, dried (SR Legacy)"),
    "green_cardamom": (170919, "Spices, cardamom (SR Legacy)"),
    "roast_turkey": (171479, "Turkey, whole, meat and skin, cooked, roasted (SR Legacy)"),
    "tortilla_chips": (167558, "Snacks, tortilla chips, plain, white corn, salted (SR Legacy)"),
    "brown_lentils": (172420, "Lentils, raw (SR Legacy)"),
    "green_lentils": (172420, "Lentils, raw (SR Legacy)"),
    "red_lentils": (174284, "Lentils, pink or red, raw (SR Legacy)"),
    "flour_tortillas": (2707824, "Tortilla, flour (FNDDS)"),
    "corn_tortillas": (2707823, "Tortilla, corn (FNDDS)"),
    "pitta": (174915, "Bread, pita, white, enriched (SR Legacy) - canon spells the key pitta"),
    "sardines": (175139, "Fish, sardine, Atlantic, canned in oil, drained solids with bone (SR Legacy)"),
    "mint": (173474, "Peppermint, fresh (SR Legacy) - FNDDS has only Mint julep for mint*"),
    "salmon": (175167, "Fish, salmon, Atlantic, farmed, raw (SR Legacy) - canon id is Foundation Foods, absent from bulk CSVs"),
    "anchovies": (174183, "Fish, anchovy, european, canned in oil, drained solids (SR Legacy)"),
    "avocado": (171705, "Avocados, raw, all commercial varieties (SR Legacy)"),
    "bell_pepper": (170108, "Peppers, sweet, red, raw (SR Legacy)"),
    "chickpea": (173756, "Chickpeas (garbanzo beans, bengal gram), mature seeds, raw (SR Legacy)"),
    "chickpeas": (173756, "Chickpeas (garbanzo beans, bengal gram), mature seeds, raw (SR Legacy)"),
    "heavy_cream": (170859, "Cream, fluid, heavy whipping (SR Legacy)"),
    "salt": (173468, "Salt, table (SR Legacy) - catalog prefix hit was Salt Pork"),
    "egg": (171287, "Egg, whole, raw, fresh (SR Legacy) - catalog row was Salted frozen egg"),
}

# Class overrides for keys with no canon fact (meat/fish/dairy/... used by
# claim checks and FSIS mapping). 'spice' etc. are composition-neutral.
CLASS_OVERRIDES: dict[str, tuple[list[str], str]] = {
    "pasta_dried": (["gluten", "plant"], "dried durum wheat pasta"),
    "wheat_noodles": (["gluten", "plant"], "wheat noodles"),
    "ramen_noodles": (["gluten", "plant", "egg"], "ramen noodles typically contain egg"),
    "all_purpose_flour": (["gluten", "plant"], "wheat flour"),
    "whole_wheat_flour": (["gluten", "plant"], "whole wheat flour"),
    "cornmeal": (["plant"], "ground corn"),
    "white_rice": (["plant"], "white rice"),
    "brown_rice": (["plant"], "brown rice"),
    "cooked_rice": (["plant"], "cooked white rice"),
    "cooked_brown_rice": (["plant"], "cooked brown rice"),
    "flattened_rice": (["plant"], "poha"),
    "farro": (["gluten", "plant"], "farro is a wheat species"),
    "couscous": (["gluten", "plant"], "semolina"),
    "gnocchi": (["gluten", "plant", "dairy"], "potato/wheat gnocchi"),
    "bread": (["gluten", "plant", "dairy"], "wheat bread may contain milk"),
    "burger_buns": (["gluten", "plant", "dairy"], "buns may contain milk"),
    "tortillas": (["gluten", "plant"], "flour tortillas"),
    "corn_tortillas": (["plant"], "corn tortillas"),
    "tortilla_chips": (["plant"], "fried corn chips"),
    "pita": (["gluten", "plant"], "wheat pita"),
    "puff_pastry": (["gluten", "plant", "dairy"], "butter puff pastry"),
    "panko": (["gluten", "plant"], "breadcrumbs"),
    "oats": (["plant"], "rolled oats"),
    "soy_sauce": (["soy", "gluten", "plant"], "brewed with wheat"),
    "miso": (["soy", "gluten", "plant"], "may be made with barley"),
    "gochujang": (["soy", "gluten", "plant"], "chili-soy paste"),
    "soy_milk": (["soy", "plant"], "soy milk"),
    "vegetable_oil": (["plant"], "neutral cooking oil"),
    "coconut_oil": (["plant"], "coconut oil"),
    "olive_oil": (["plant"], "olive oil"),
    "sesame_oil": (["sesame", "plant"], "sesame oil"),
    "ghee": (["dairy", "animal"], "clarified butter"),
    "salt": (["mineral"], "salt"),
    "honey": (["honey", "animal"], "not vegan"),
    "chili_powder": (["plant"], "spice blend"),
    "ras_el_hanout": (["plant"], "spice blend"),
    "jerk_seasoning": (["plant"], "spice blend"),
    "curry_powder": (["plant"], "spice blend"),
    "garam_masala": (["plant"], "spice blend"),
    "cocoa_powder": (["plant"], "cocoa"),
    "coffee": (["plant"], "brewed coffee"),
    "black_tea": (["plant"], "black tea"),
    "cola": (["plant"], "cola beverage"),
    "apple_cider": (["plant"], "apple cider"),
    "hot_sauce": (["plant"], "chili-vinegar sauce"),
    "ketchup": (["plant"], "tomato ketchup"),
    "mustard": (["plant"], "mustard"),
    "cranberry_sauce": (["plant"], "fruit sauce"),
    "pomegranate_molasses": (["plant"], "fruit molasses"),
    "tamarind_paste": (["plant"], "tamarind paste"),
    "stock": (["unknown"], "composition depends on product"),
    "beef_stock": (["meat", "unknown"], "may contain meat or milk"),
    "vegetable_stock": (["plant", "unknown"], "may contain milk or wheat"),
    "mayonnaise": (["egg", "animal"], "egg emulsion"),
    "sour_cream": (["dairy"], "fermented cream"),
    "buttermilk": (["dairy"], "cultured milk"),
    "ricotta": (["dairy"], "whey cheese"),
    "cream": (["dairy"], "cream"),
    "cheese": (["dairy"], "cheese"),
    "nduja": (["meat"], "spreadable cured pork"),
    "chorizo": (["meat"], "cured pork sausage"),
    "salt_pork": (["meat"], "cured pork"),
    "sausages": (["meat", "unknown"], "may contain milk or wheat fillers"),
    "duck_legs": (["meat"], "duck"),
    "roast_turkey": (["meat"], "cooked turkey"),
    "beef_chuck": (["meat"], "beef cut"),
    "pork_shoulder": (["meat"], "pork cut"),
    "lamb_shank": (["meat"], "lamb cut"),
    "lamb_shoulder": (["meat"], "lamb cut"),
    "white_fish": (["fish"], "generic white fish"),
    "crab_meat": (["shellfish"], "crab"),
    "anchovies": (["fish"], "cured fish"),
    "sardines": (["fish"], "canned sardines"),
    "tuna_canned": (["fish"], "canned tuna"),
    "catfish": (["fish"], "catfish"),
    "haddock": (["fish"], "haddock"),
    "sea_bass": (["fish"], "sea bass"),
    "hominy": (["plant"], "nixtamalized corn"),
    "pickles": (["plant"], "pickled cucumber"),
    "beansprouts": (["plant"], "mung bean sprouts"),
    "sesame_seeds": (["sesame", "plant"], "sesame"),
    "pine_nuts": (["tree_nut", "plant"], "pine nuts"),
    "peanuts": (["peanut", "plant"], "peanuts"),
    "almonds": (["tree_nut", "plant"], "almonds"),
    "peanut_butter": (["peanut", "plant"], "ground peanuts"),
    "tahini": (["sesame", "plant"], "sesame paste"),
    "pomegranate_seeds": (["plant"], "fresh arils"),
    "besan": (["plant"], "chickpea flour"),
    # animal classes (claim checks + FSIS mapping)
    "chicken_breast": (["meat"], "poultry"),
    "chicken_thighs": (["meat"], "poultry"),
    "chicken_thigh": (["meat"], "poultry"),
    "chicken_drumsticks": (["meat"], "poultry"),
    "ground_chicken": (["meat"], "ground poultry"),
    "ground_beef": (["meat"], "ground beef"),
    "ground_pork": (["meat"], "ground pork"),
    "flank_steak": (["meat"], "beef cut"),
    "pork_chop": (["meat"], "pork cut"),
    "boneless_pork_chops": (["meat"], "pork cut"),
    "lamb": (["meat"], "lamb"),
    "bacon": (["meat"], "cured pork belly"),
    "italian_sausage": (["meat", "unknown"], "may contain milk or wheat fillers"),
    "salmon": (["fish"], "salmon"),
    "cod": (["fish"], "cod"),
    "tuna": (["fish"], "tuna"),
    # dairy
    "milk": (["dairy"], "milk"),
    "butter": (["dairy"], "butter"),
    "yogurt": (["dairy"], "yogurt"),
    "greek_yogurt": (["dairy"], "strained yogurt"),
    "heavy_cream": (["dairy"], "cream"),
    "cheddar": (["dairy"], "cheese"),
    "sharp_cheddar": (["dairy"], "cheese"),
    "parmesan": (["dairy"], "cheese"),
    "mozzarella": (["dairy"], "cheese"),
    "feta": (["dairy"], "cheese"),
    "paneer": (["dairy"], "cheese"),
    "halloumi": (["dairy"], "cheese"),
    # soy / gluten / tree-nut allergens
    "edamame": (["soy", "plant"], "young soybeans"),
    "tofu": (["soy", "plant"], "bean curd"),
    "orzo": (["gluten", "plant"], "wheat pasta"),
    "breadcrumbs": (["gluten", "plant"], "wheat breadcrumbs"),
    "coconut_milk": (["plant"], "canned coconut milk"),
}

# Category taxonomy for vocabulary entries (bundle schema examples: dairy_egg,
# vegetable, condiment, grain, meat, fish, spice, other).
CATEGORY_OVERRIDES: dict[str, str] = {}

CLASS_TO_CATEGORY = {
    "meat": "meat", "fish": "fish", "shellfish": "shellfish", "dairy": "dairy_egg",
    "egg": "dairy_egg", "animal": "other", "animal-derived": "other",
    "mineral": "condiment", "fungus": "vegetable", "insect-product": "other",
}

FRUIT_KEYS = {
    "apple", "banana", "lemon", "lime", "orange", "mango", "grapes", "watermelon",
    "pineapple", "blueberries", "dried_apricots", "dried_dates", "pomegranate_seeds",
    "cranberry_sauce", "avocado",
}
GRAIN_KEYS = {
    "pasta_dried", "wheat_noodles", "ramen_noodles", "rice", "white_rice", "brown_rice",
    "cooked_rice", "cooked_brown_rice", "flattened_rice", "farro", "couscous", "oats",
    "all_purpose_flour", "whole_wheat_flour", "cornmeal", "bread", "burger_buns",
    "tortillas", "corn_tortillas", "tortilla_chips", "pita", "puff_pastry", "panko",
    "gnocchi", "rice_noodles",
}
SPICE_KEYS = {
    "cumin", "ground_cumin", "cumin_seeds", "coriander_ground", "turmeric",
    "smoked_paprika", "paprika", "garam_masala", "curry_powder", "ras_el_hanout",
    "cinnamon", "cayenne", "red_pepper_flakes", "chili_powder", "cardamom",
    "bay_leaves", "oregano", "thyme", "rosemary", "basil", "parsley", "cilantro",
    "mint", "chives", "dill", "ginger", "garlic", "jerk_seasoning", "black_pepper",
    "cocoa_powder", "salt", "red_wine_vinegar", "rice_vinegar", "capers",
}
CONDIMENT_KEYS = {
    "soy_sauce", "miso", "fish_sauce", "gochujang", "harissa", "chipotle",
    "mustard", "ketchup", "hot_sauce", "mayonnaise", "vegetable_oil", "coconut_oil",
    "olive_oil", "sesame_oil", "ghee", "pomegranate_molasses", "tamarind_paste",
    "honey", "brown_sugar", "sugar", "maple_syrup", "stock", "beef_stock",
    "vegetable_stock", "apple_cider", "coffee", "black_tea", "cola",
    "roasted_red_peppers", "preserved_lemon", "hummus", "cranberry_sauce",
}


def category_for(key: str, classes: list[str]) -> str:
    if key in CATEGORY_OVERRIDES:
        return CATEGORY_OVERRIDES[key]
    if key in SPICE_KEYS:
        return "spice"
    if key in CONDIMENT_KEYS:
        return "condiment"
    if key in FRUIT_KEYS:
        return "fruit"
    if key in GRAIN_KEYS:
        return "grain"
    for c in classes:
        if c in CLASS_TO_CATEGORY:
            return CLASS_TO_CATEGORY[c]
    return "vegetable" if any(c in {"plant"} for c in classes) else "other"


# Qualifier words that disqualify an FDC candidate when the base food is
# generic (spec 1 rule 2: qualifiers that change the food are rejected).
FDC_REJECT = re.compile(
    
    r"\b(salted|frozen|juice|dressing|flour|parfait|yogurt|yoghurt|bread|bready|"
    r"candied|glazed|sweetened|in syrup|pie|cake|cookie|chips|flavored|flavoured|"
    r"sauce|spread|filled|coated|battered|fried|infant|human|breast milk|drink|beverage|"
    r"croissant|granola|ice cream|pudding|soup|stew|casserole|salad|sandwich|burrito|"
    r"taco|pizza|noodle soup|lo mein|chow mein|fried rice|dried|rotisserie|topping|"
    r"fat free|low fat|lowfat|nonfat|reduced fat|instant|condensed|evaporated|"
    r"powdered|imitation|substitute|deli|luncheon|smoked|parboiled|uncle ben|ben's|"
    r"kraft|barilla|bar house| converting| converted|instant)\b",
    re.IGNORECASE,
)


# Category-noun hints for the FDC head-noun second pass ("Cheese, cheddar").
CATEGORY_HINT = {
    "cheddar": "cheese", "sharp_cheddar": "cheese", "feta": "cheese",
    "mozzarella": "cheese", "parmesan": "cheese", "paneer": "cheese",
    "halloumi": "cheese", "tuna": "fish", "catfish": "fish", "tilapia": "fish",
    "sea_bass": "fish", "haddock": "fish", "cod": "fish", "salmon": "fish",
    "duck_legs": "duck", "duck": "duck", "lamb_shanks": "lamb",
    "flank_steak": "beef", "beef_chuck": "beef", "pork_shoulder": "pork",
    "pork_chop": "pork", "boneless_pork_chops": "pork", "ground_beef": "beef",
    "ground_pork": "pork", "ground_chicken": "chicken", "bacon": "bacon",
    "nduja": "pork", "chorizo": "sausage", "sausages": "sausage",
    "italian_sausage": "sausage", "shrimp": "shrimp", "crab_meat": "crab",
    "anchovies": "anchovy", "sardines_in_oil": "sardine", "sardines": "sardine",
}


def display_name(key: str) -> str:
    return key.replace("_", " ").capitalize()


def load_corpus_names() -> tuple[set[str], list[str]]:
    names: set[str] = set()
    surfaces_in_order: list[str] = []
    with (REPO / "data/recipes/corpus.jsonl").open() as f:
        for line in f:
            r = json.loads(line)
            for ing in r["ingredients"]:
                n = ing["name"]
                names.add(n)
                surfaces_in_order.append(n)
    return names, surfaces_in_order


def load_catalog():
    con = sqlite3.connect(REPO / "apps/ios/Resources/usda_ingredient_catalog.sqlite")
    cat: dict[str, list[tuple[int, str]]] = defaultdict(list)
    for fdc, dn, nn in con.execute(
        "select fdc_id, display_name, normalized_name from ingredient_catalog"
    ):
        cat[normalize_name(dn)].append((fdc, dn))
        if nn:
            cat[normalize_name(nn)].append((fdc, dn))
    for fdc, alias in con.execute(
        "select i.fdc_id, a.alias from ingredient_aliases a "
        "join ingredient_catalog i on i.id = a.ingredient_id"
    ):
        cat[normalize_name(alias)].append((fdc, ""))
    # per-100g nutrition keyed by fdc_id (ingredients.id == ingredient_catalog.fdc_id)
    nutri: dict[int, dict] = {}
    for name, kcal, pro, carbs, fat, fiber, sugar, sodium, fdc in con.execute(
        "select i.name, i.calories, i.protein, i.carbs, i.fat, i.fiber, i.sugar, "
        "i.sodium, c.fdc_id from ingredient_catalog c inner join ingredients i on i.id = c.fdc_id"
    ):
        nutri[fdc] = {
            "kcal": kcal, "protein_g": pro, "carbs_g": carbs, "fat_g": fat,
            "fiber_g": fiber, "sugar_g": sugar, "sodium_mg": round(sodium * 1000, 1),
        }
        cat.setdefault(normalize_name(name), []).append((fdc, name))
    return cat, nutri


def load_canon():
    ids = json.loads((Path("/tmp/canon/identities.json")).read_text())["ingredients"]
    facts = json.loads((Path("/tmp/canon/facts.json")).read_text())["facts"]
    simple: dict[str, dict] = {}
    synonyms: dict[str, list[str]] = defaultdict(list)
    for i in ids:
        key = slugify(i["key"])
        if i.get("kind") == "simple":
            simple[key] = i
        synonyms[normalize_name(i["display"])].append(key)
        for s in i.get("synonyms", []):
            synonyms[normalize_name(s)].append(key)
    return simple, synonyms, facts


def load_fdc():
    """fdc foods: fdc_id -> (description, data_type); nutrients per fdc_id."""
    foods: dict[int, tuple[str, str]] = {}
    nutrients: dict[int, dict] = {}
    portions: dict[int, list[str]] = {}
    # SR Legacy ids (1008/1003/1005/1004/1079/2000/1093) and FNDDS 2024 ids
    # (208/203/205/204/291/269/307) for the same seven fields.
    NUTRIENT_IDS = {"kcal": {1008, 208}, "protein_g": {1003, 203},
                    "carbs_g": {1005, 2050, 205}, "fat_g": {1004, 204},
                    "fiber_g": {1079, 291}, "sugar_g": {2000, 1063, 269},
                    "sodium_mg": {1093, 307}}
    for dtype, d in FDC_DIRS.items():
        with (d / "food.csv").open() as f:
            for row in csv.DictReader(f):
                foods[int(row["fdc_id"])] = (row["description"], dtype)
        with (d / "food_nutrient.csv").open() as f:
            for row in csv.DictReader(f):
                fid = int(row["fdc_id"])
                nid = int(row["nutrient_id"])
                for field, ids in NUTRIENT_IDS.items():
                    if nid in ids and field not in nutrients.setdefault(fid, {}):
                        nutrients[fid][field] = float(row["amount"])
                # energy in kJ fallback handled by preferring 1008 rows (present in both)
        p = d / "food_portion.csv"
        if p.exists():
            with p.open() as f:
                for row in csv.DictReader(f):
                    fid = int(row["fdc_id"])
                    if row.get("portion_description"):
                        portions.setdefault(fid, []).append(row["portion_description"])
                    elif row.get("gram_weight") and row.get("measure_unit_id"):
                        pass
    return foods, nutrients, portions


PER100_FIELDS = ("kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g",
                 "sodium_mg")


def merge_nutrition(primary: dict | None, fallback: dict | None) -> dict | None:
    """Merge two per-100g dicts, preferring the primary source per field.

    A field missing or zero in the primary is taken from the fallback when the
    fallback carries a positive value; neither source synthesizes anything.
    The bundle schema requires all seven fields, so a nutrient the FDC row
    does not list is emitted as 0.0 (the food carries none at measurement
    resolution), never omitted.
    """
    if not primary and not fallback:
        return None
    out = {k: v for k, v in (fallback or {}).items()}
    out.update({k: v for k, v in (primary or {}).items() if v})
    for k, v in (fallback or {}).items():
        if v and not out.get(k):
            out[k] = v
    if not out:
        return None
    return {f: round(float(out.get(f, 0.0)), 2) for f in PER100_FIELDS}


def main() -> None:
    corpus_names, _ = load_corpus_names()
    legacy = json.load(open(REPO / "apps/ios/Resources/data.json"))["ingredients"]
    legacy_by_name = {v[0]: int(k) for k, v in legacy.items()}
    cat, cat_nutri = load_catalog()
    canon_simple, canon_synonyms, facts = load_canon()
    fdc_foods, fdc_nutrients, fdc_portions = load_fdc()

    # ---- 1. resolve every surface name to a canonical key ------------------
    mappings: dict[str, dict] = {}

    def match_existing(k: str) -> str | None:
        variants = {k, singular(k), k + "s"}
        for kk in variants:
            if kk in KEY_OVERRIDES:
                return KEY_OVERRIDES[kk][0]
        for kk in variants:
            if kk in canon_simple:
                return kk
        for kk in variants:
            if kk.replace(" ", "_") in legacy_by_name or kk in legacy_by_name:
                key = kk.replace(" ", "_")
                return key if key in legacy_by_name else kk
        for kk in variants:
            if kk in cat:
                return slugify(kk)
        for kk in variants:
            if kk in canon_synonyms and len(set(canon_synonyms[kk])) == 1:
                return canon_synonyms[kk][0]
        return None

    for surface in sorted(corpus_names):
        n = normalize_name(surface)
        key = match_existing(n)
        method = None
        if key:
            method = "direct"
        else:
            base = strip_prep(n)
            if base and base != n:
                key = match_existing(base)
                if key:
                    method = "prep-strip"
            if not key:
                # synonym lookup on the stripped base
                if base in canon_synonyms and len(set(canon_synonyms[base])) == 1:
                    key = canon_synonyms[base][0]
                    method = "canon-synonym"
            if not key:
                key = slugify(base or n)
                method = "new-food"
        mappings[n] = {"key": key, "method": method, "surface": surface}

    # legacy names map to their own keys
    for name, lid in legacy_by_name.items():
        n = normalize_name(name)
        if n not in mappings:
            mappings[n] = {"key": name, "method": "legacy", "surface": name}

    all_keys = sorted({m["key"] for m in mappings.values()})

    # ---- 2. resolve each key: classes, category, fdc_id, nutrition ---------
    # catalog lookup index for keys
    vocab: list[dict] = []
    fdc_new_rows: dict[str, dict] = {}
    unresolved_keys: list[str] = []

    def catalog_entry_for(key: str) -> tuple[int, str] | None:
        """Exact match first, then prefix candidates with qualifier rejection."""
        nv0 = ""
        for variant in (key, singular(key.replace("_", " ")), key.replace("_", " ")):
            nv0 = normalize_name(variant)
            hits = cat.get(nv0)
            if hits and len({h[0] for h in hits}) == 1:
                return hits[0]
        vset = {nv0, singular(nv0), nv0 + "s", singular(nv0) + "s"}
        cands: set[int] = set()
        for cname, hits in sorted(cat.items()):
            toks = cname.split()
            if toks and toks[0] in vset and not any(FDC_REJECT.search(t) for t in toks[1:]):
                for fdc, _ in hits:
                    cands.add(fdc)
        if len(cands) == 1:
            fdc = sorted(cands)[0]
            ref = next((dn for fdn, dn in cat.get(nv0, []) if fdn == fdc), "")
            return fdc, ref
        return None

    def word_forms(w: str) -> set[str]:
        f = {w, w + "s", w + "es", singular(w), singular(w) + "s", singular(w) + "es"}
        if w.endswith("y"):
            f.add(w[:-1] + "ies")
        return f

    def _fdc_search(words: list[str]) -> tuple[int, str, str] | None:
        """Scan FDC bulk CSVs for a description led by the food words."""
        best = None
        forms = {w: word_forms(w) for w in words}
        for fid, (desc, dtype) in fdc_foods.items():
            dl = desc.lower()
            tokens = [t for t in re.split(r"[^a-z]+", dl) if t]
            if len(tokens) < len(words):
                continue
            head = tokens[0]
            head_word = next((w for w in words if head in forms[w]), None)
            if head_word is None:
                continue
            rest = [w for w in words if w != head_word]
            tail = tokens[1:]
            if any(FDC_REJECT.search(t) for t in tail):
                continue
            if not all(any(t in forms[w] for t in tail) for w in rest):
                continue
            rank = {"survey_fndds_food": 2, "sr_legacy_food": 1}[dtype]
            score = (fid in fdc_nutrients, -len(tokens), rank)
            if best is None or score > best[0]:
                best = (score, fid, desc, dtype)
        if best:
            return best[1], best[2], best[3]
        return None

    def fdc_search(key: str) -> tuple[int, str, str] | None:
        """FDC lookup: strip state words, then a category-hint second pass.

        FDC descriptions lead with the head noun ("Cheese, cheddar"), so keys
        like `cheddar` retry with the category noun prepended.
        """
        stop = {"dried", "canned", "cooked", "fresh", "frozen", "whole", "fillet",
                "fillets", "boneless", "skinless", "bone", "raw", "chopped"}
        words = [w for w in key.split("_") if w not in stop]
        if not words:
            return None
        hit = _fdc_search(words)
        if hit:
            return hit
        hint = CATEGORY_HINT.get(key)
        if hint and hint not in words:
            return _fdc_search([hint] + words)
        return None

    for key in all_keys:
        if key in CLASS_OVERRIDES:
            classes, class_note = CLASS_OVERRIDES[key]
        else:
            classes = ["unknown"]
            class_note = "no curated class — defaults to unknown (claim-blocking)"
            unresolved_keys.append(key)

        fdc_id = None
        fdc_ref = None
        fdc_src = None
        per100 = None
        canon_hit = canon_simple.get(key)
        pin = FDC_PINS.get(key)
        if pin:
            fdc_id, fdc_ref = pin
            fdc_src = "hand-verified pin (build_vocab.py FDC_PINS)"
            per100 = merge_nutrition(fdc_nutrients.get(fdc_id),
                                     cat_nutri.get(fdc_id))
        elif canon_hit and canon_hit.get("usdaFdcId"):
            fdc_id = canon_hit["usdaFdcId"]
            fdc_ref = canon_hit.get("usdaRef") or ""
            fdc_src = "ingredient-facts canon usdaFdcId (curated)"
            per100 = merge_nutrition(fdc_nutrients.get(fdc_id),
                                     cat_nutri.get(fdc_id))
        elif cat_hit := catalog_entry_for(key):
            fdc_id, fdc_ref = cat_hit
            fdc_src = "bundled catalog usda_ingredient_catalog.sqlite"
            per100 = merge_nutrition(fdc_nutrients.get(fdc_id),
                                     cat_nutri.get(fdc_id))
        else:
            hit = fdc_search(key)
            if hit:
                fdc_id, fdc_ref, fdc_src_dtype = hit
                fdc_src = f"FoodData Central {fdc_src_dtype} (CC0 bulk CSV)"
                per100 = merge_nutrition(fdc_nutrients.get(fdc_id), None)
                if per100:
                    fdc_new_rows[str(fdc_id)] = {
                        "ref": fdc_ref, "data_type": fdc_src_dtype, "source": fdc_src,
                        "per_100g": per100, "for_key": key,
                    }
        if fdc_id is None:
            fdc_ref = "no confident USDA row — never guessed"

        entry = {
            "key": key,
            "display_name": display_name(key),
            "fdc_id": fdc_id,
            "fdc_ref": fdc_ref,
            "category": category_for(key, classes),
            "classes": classes,
            "class_note": class_note,
            "nutrition_source": fdc_src or ("bundled catalog" if fdc_id else "none"),
            "per_100g": per100,
            "aliases": [],
            "unit_weights": {},
        }
        vocab.append(entry)

    # ---- 3. aliases + unit weights from corpus evidence --------------------
    by_key = {e["key"]: e for e in vocab}
    for n, m in mappings.items():
        e = by_key[m["key"]]
        if m["surface"].lower() not in [a.lower() for a in e["aliases"]]:
            e["aliases"].append(m["surface"].lower())
    for key, syns in canon_synonyms.items():
        for k in set(syns):
            if k in by_key and key not in [a.lower() for a in by_key[k]["aliases"]]:
                by_key[k]["aliases"].append(key)

    grams_by_key_unit: dict[tuple[str, str], list[float]] = defaultdict(list)
    refs_by_key_unit: dict[tuple[str, str], set[str]] = defaultdict(set)
    with (REPO / "data/recipes/corpus.jsonl").open() as f:
        for line in f:
            r = json.loads(line)
            for ing in r["ingredients"]:
                q = ing["qty"]
                n = normalize_name(ing["name"])
                if n not in mappings:
                    continue
                k = mappings[n]["key"]
                if q["kind"] in ("household",) and q.get("grams") and q.get("value"):
                    w = q["grams"] / q["value"]
                    grams_by_key_unit[(k, q["unit"])].append(w)
                    if q.get("conversion_ref"):
                        refs_by_key_unit[(k, q["unit"])].add(q["conversion_ref"])
                elif q["kind"] == "source_grams" and q.get("grams"):
                    grams_by_key_unit[(k, "serving")].append(q["grams"])

    for (k, unit), weights in sorted(grams_by_key_unit.items()):
        by_key[k]["unit_weights"][unit] = {
            "grams_per_unit": round(statistics.median(weights), 2),
            "n": len(weights),
            "source": "corpus conversion_ref: " + ", ".join(sorted(refs_by_key_unit[(k, unit)])) or "corpus median",
        }

    # legacy data.json typical_unit gives one honest unit weight for legacy keys
    for v in legacy.values():
        name = v[0]
        k = name
        if k not in by_key:
            continue
        tu = v[8]  # "1 large (50g)"
        m = re.search(r"\((\d+(?:\.\d+)?)g\)", tu or "")
        if m and not by_key[k]["unit_weights"]:
            unit_desc = re.match(r"([^ (]+)", tu).group(1)
            by_key[k]["unit_weights"][unit_desc] = {
                "grams_per_unit": float(m.group(1)),
                "n": 1,
                "source": f"legacy data.json typical_unit",
            }

    for e in vocab:
        e["aliases"] = sorted(set(e["aliases"]))

    # ---- 4. legacy identity map (spec §1 rules against the bundled catalog) -
    identity_entries = []
    for lid in range(1, 51):
        name = next(n for n, i in legacy_by_name.items() if i == lid)
        key = name
        k = normalize_name(name)
        exact = {h[0] for h in cat.get(k, [])}
        singular_hits = {h[0] for h in cat.get(singular(k), [])} - exact
        prefix_cands = set()
        if not exact:
            for cname, hits in sorted(cat.items()):
                if cname.startswith(singular(k)) and len(cname) > len(singular(k)):
                    for fdc, _ in hits:
                        prefix_cands.add(fdc)
        # reject qualified forms for the generic base
        rejected = {f for f in prefix_cands if any(FDC_REJECT.search((fdc_foods.get(f, ("?",))[0] if f not in cat_nutri else next((dn for dn, _ in cat.get(normalize_name(by_key[key]["display_name"]), [])), "?"))) for f in [f])} if False else set()
        candidates = sorted(exact | prefix_cands)
        if len(exact) == 1:
            status, rule, fdc = "resolved", "unique display-name or alias match in the bundled catalog", sorted(exact)[0]
        elif len(exact) > 1:
            status, rule, fdc = "proposed", "multiple catalog matches — single best candidate pending confirmation", sorted(exact)[0]
        elif len(prefix_cands) == 1:
            status, rule, fdc = "proposed", "unique display-name prefix match on generic qualifier", sorted(prefix_cands)[0]
        elif prefix_cands:
            status, rule, fdc = "unresolved", "multi-variant food: all catalog candidates are qualified forms", None
        elif singular_hits:
            status, rule, fdc = "proposed", "unique singular-form catalog match", sorted(singular_hits)[0]
        else:
            status, rule, fdc = "unresolved", "no acceptable candidate in the bundled catalog", None
        # The vocabulary resolution is authoritative: hand-verified pins and
        # bulk-CSV rows beat a bundled-catalog prefix hit (e.g. egg resolved
        # to the catalog's Salted frozen egg before the pin existed).
        if by_key.get(key, {}).get("fdc_id") is not None:
            vocab_fdc = by_key[key]["fdc_id"]
            if vocab_fdc != fdc:
                fdc = vocab_fdc
                rule = "vocabulary resolution (hand-verified pin or bulk-CSV row)"
                if vocab_fdc not in candidates:
                    candidates = sorted(candidates + [vocab_fdc])
        identity_entries.append({
            "legacy_id": lid, "legacy_name": name, "key": key, "fdc_id": fdc,
            "status": status, "match_rule": rule, "candidates": candidates,
        })

    legacy_map = {
        "schema": "https://fridgeluck.app/schemas/ingredient-identity.schema.json",
        "legacy_count": 50,
        "entries": identity_entries,
    }

    # ---- 5. emit ------------------------------------------------------------
    ING_DIR.mkdir(parents=True, exist_ok=True)
    vocab_doc = {
        "schema": "https://fridgeluck.app/schemas/ingredient-vocabulary-v1.json",
        "sources": {
            "bundled_catalog": "apps/ios/Resources/usda_ingredient_catalog.sqlite (800 rows)",
            "fdc_bulk": "FoodData Central survey FNDDS 2024-10-31 + SR Legacy 2018-04 bulk CSVs, CC0",
            "canon": "ingredient-facts canon, branch eval/scorecard-runner canon/ingredient-facts (read-only)",
        },
        "entries": sorted(vocab, key=lambda e: e["key"]),
    }
    (ING_DIR / "vocabulary.json").write_text(json.dumps(vocab_doc, indent=2, ensure_ascii=False) + "\n")
    (ING_DIR / "name-mappings.json").write_text(
        json.dumps({
            "schema": "https://fridgeluck.app/schemas/ingredient-name-mappings-v1.json",
            "mappings": dict(sorted(mappings.items())),
        }, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    )
    (ING_DIR / "fdc-new-rows.json").write_text(
        json.dumps({
            "schema": "https://fridgeluck.app/schemas/fdc-new-rows-v1.json",
            "note": "FDC rows added beyond the bundled 800-catalog; per-100g pulled from the same bulk CSVs",
            "rows": dict(sorted(fdc_new_rows.items(), key=lambda kv: int(kv[0]))),
        }, indent=2, ensure_ascii=False) + "\n"
    )
    (REPO / "data/recipes/legacy-ingredient-map.json").write_text(
        json.dumps(legacy_map, indent=2, ensure_ascii=False) + "\n"
    )

    # ---- 6. audit ------------------------------------------------------------
    st = Counter(e["status"] for e in identity_entries)
    print(f"keys: {len(vocab)}  surfaces: {len(mappings)}")
    print(f"identity map statuses: {dict(st)}")
    print(f"fdc new rows: {len(fdc_new_rows)}")
    print(f"keys without fdc_id: {[e['key'] for e in vocab if e['fdc_id'] is None]}")
    print(f"keys without class: {unresolved_keys}")
    print(f"keys without per_100g: {sorted(e['key'] for e in vocab if e['per_100g'] is None)}")


if __name__ == "__main__":
    main()
