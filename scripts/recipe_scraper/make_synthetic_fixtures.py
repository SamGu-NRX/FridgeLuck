"""Generate the synthetic scraper-cache fixtures read by generate_rights_audit.py.

The repo formerly committed BBC Good Food scrape caches under .cache/
(unlicensed full text; see data/recipes/RIGHTS-AUDIT.md). Those caches were
removed and replaced by these SYNTHETIC fixtures: same record shape, entirely
fictional content, fictional example.com URLs, and an explicit
``"synthetic": true`` marker on every record.

Deterministic by construction: selection is index arithmetic (no RNG), so a
re-run regenerates byte-identical files:

    python3 scripts/recipe_scraper/make_synthetic_fixtures.py

Offline tool: reads only apps/ios/Resources/data.json (to assert the
fixtures' titles stay disjoint from bundled titles), writes only the two
fixture files. No network, no third-party deps, and no access to the removed
scrape caches - nothing here derives from any real site's content.
"""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_JSON = REPO_ROOT / "apps" / "ios" / "Resources" / "data.json"
CACHE_DIR = REPO_ROOT / "scripts" / "recipe_scraper" / ".cache"

MAIN_FIXTURE = CACHE_DIR / "synthetic_fixtures.json"  # 152 records
TEST_FIXTURE = CACHE_DIR / "synthetic_fixtures.test.json"  # 3 records

MAIN_RECORDS = 152
TEST_RECORDS = 3

# Record shape mirrors the removed scrape caches (profiled 2026-10-11):
# keys title / source_url / servings_original / servings_target / ingredients
# / steps, with ingredients a list of dicts keyed raw / scaled_raw / name /
# amount_value (int|null) / amount_unit (str|null) / prep_actions (list of
# str), servings ints, steps a list of strings. Observed ranges the fixtures
# cover: main file 4-24 ingredients and 1-14 steps per record; test file
# 8-11 ingredients and 1-8 steps.
RECORD_KEYS = [
    "title",
    "source_url",
    "servings_original",
    "servings_target",
    "ingredients",
    "steps",
    "synthetic",
]
INGREDIENT_KEYS = [
    "raw",
    "scaled_raw",
    "name",
    "amount_value",
    "amount_unit",
    "prep_actions",
]

# Everything below is authored for FridgeLuck; no real site's wording.
TITLE_ADJECTIVES = [
    "Weeknight",
    "Copperpot",
    "Lantern",
    "Rainyday",
    "Cornerstall",
    "Slow-Sunday",
    "Small-Hold",
    "Winterwindow",
    "Meadowlane",
    "Harbourlight",
    "Orchardrow",
    "Tidemark",
    "Hillcrest",
    "Pewter",
    "Amberlyn",
    "Marblestep",
    "Yellowdoor",
    "Kitchen-Garden",
    "Thistledown",
    "Brookside",
]
TITLE_CORES = [
    "Barley",
    "Chickpea",
    "Lentil",
    "Millet",
    "Farro",
    "Buckwheat",
    "Spelt",
    "Rye",
    "Polenta",
    "Couscous",
    "Potato",
    "Sweet Potato",
    "Parsnip",
    "Turnip",
    "Beetroot",
    "Carrot",
    "Leek",
    "Cabbage",
    "Kohlrabi",
    "Fennel",
    "Green Pea",
    "Butter Bean",
    "Tomato",
    "Bell Pepper",
    "Squash",
    "Mushroom",
    "Tofu",
    "Egg",
    "Yogurt",
    "Oat",
]
TITLE_FORMS = [
    "Stew",
    "Bake",
    "Braise",
    "Pilaf",
    "Gratin",
    "Skillet Supper",
    "Fritter Plate",
    "Soup",
    "Bowl",
    "Broth",
    "Casserole",
    "Pan Loaf",
    "Hash",
    "Ragout",
    "Porridge",
    "Tray Supper",
    "Simmer Pot",
    "Warm Salad",
    "Mash Pot",
    "Skillet Pie",
    "Skillet Bread",
    "Steam Pot",
    "Cold Supper",
]

# (name, unit, amount) triplets; household units only, amounts integers.
INGREDIENT_ITEMS = [
    ("carrot", "g", 120),
    ("leek", "g", 150),
    ("waxy potato", "g", 250),
    ("sweet potato", "g", 300),
    ("yellow onion", "g", 110),
    ("garlic clove", "clove", 2),
    ("canned chickpeas", "g", 240),
    ("green lentils", "g", 90),
    ("pearl barley", "g", 80),
    ("buckwheat groats", "g", 85),
    ("millet grain", "g", 85),
    ("spelt grains", "g", 90),
    ("rye flakes", "g", 80),
    ("rolled oats", "g", 60),
    ("polenta meal", "g", 75),
    ("couscous", "g", 75),
    ("vegetable stock cube", "cube", 1),
    ("passata", "ml", 200),
    ("chopped tomatoes", "tin", 400),
    ("coconut milk", "ml", 200),
    ("whole-milk yogurt", "tbsp", 3),
    ("butter", "g", 20),
    ("olive oil", "tbsp", 2),
    ("sunflower oil", "tbsp", 2),
    ("smoked paprika", "tsp", 1),
    ("ground cumin", "tsp", 1),
    ("coriander seed", "tsp", 1),
    ("ground turmeric", "tsp", 1),
    ("dried thyme", "tsp", 1),
    ("bay leaf", "leaf", 1),
    ("salt", None, None),
    ("black pepper", None, None),
    ("lemon", None, 1),
    ("eggs", None, 2),
    ("button mushrooms", "g", 200),
    ("fennel bulb", "bulb", 1),
    ("kohlrabi", "g", 200),
    ("savoy cabbage", "g", 200),
    ("frozen peas", "g", 150),
    ("firm tofu", "g", 200),
    ("sunflower seeds", "tbsp", 2),
    ("pumpkin seeds", "tbsp", 2),
]

PREP_ACTIONS = [
    "diced",
    "sliced thin",
    "grated",
    "torn",
    "chopped coarse",
    "minced",
    "cut into batons",
    "left whole",
    "crumbled",
    "rinsed",
]

STEP_SENTENCES = [
    "Warm a wide pan over a steady medium heat and let the oil loosen before anything else goes in.",
    "Tip the aromatics in and stir until the kitchen smells bright and the edges catch a little colour.",
    "Add the firm vegetables first so they take the heat longer than the tender leaves.",
    "Pour in enough stock to come halfway up the pile and bring everything to a lazy bubble.",
    "Drop the heat to a murmur, fit the lid ajar, and let the pot do the work while you clear the board.",
    "Stir once from the bottom, scraping any good stuck bits back into the sauce.",
    "Taste for salt at the end of cooking rather than the start, when the liquid has reduced.",
    "Pull the pan off the heat and let it sit for a few minutes so the grains drink the last of the liquid.",
    "Toast the dry spices in the empty pan until they turn one shade darker, then set them aside.",
    "Sear the pieces in a single layer, leaving space between them so they brown instead of stew.",
    "Turn the pieces when the undersides lift easily, and give them another minute on the second side.",
    "Fold the soft ingredients through gently so they hold their shape.",
    "Scatter the fresh herbs over at the table rather than the stove to keep them lively.",
    "Finish with a squeeze of lemon and taste once more before serving.",
    "Keep a kettle of hot water nearby so the pot never stops simmering when you top it up.",
    "Blend half the soup and stir it back through to thicken the rest without cream.",
    "Press the mixture firmly into the dish so it holds together when it cools slightly.",
    "Let the bake rest five minutes before cutting so the portions come out clean.",
    "Warm the plates while the last step finishes; the food stays livelier that way.",
    "Rinse the grains until the water runs clearer, then drain them well.",
    "Soak the pulses beforehand if you have planned ahead; otherwise add a few minutes to the simmer.",
    "Whisk the dressing until it looks cloudy and coats the back of a spoon.",
    "Toss everything while still warm so the flavours settle into each other.",
    "Chill the bowl for twenty minutes if you want the salad crisper than the day allows.",
    "Spread the topping evenly and press it down lightly with the back of a spoon.",
    "Check the pan between stirrings; a quiet sizzle means the heat is right.",
    "When the surface looks set at the edges but loose in the middle, it is time to take it out.",
    "Grate the hard cheese finely so a small amount goes a long way.",
    "Crumble the stock cube straight into the pan and stir it through the oil for a deeper base.",
    "Rest the cooked pieces on a warm plate, loosely covered, while the sauce reduces.",
    "Bring the sauce back to a bubble, then slide everything in to coat.",
    "Skim any foam from the surface for a clearer broth.",
    "Set the timer for the shortest simmer in the range and check from there.",
    "Give the pot a gentle shake instead of a stir if you want the pieces to stay whole.",
    "Wipe the bowl clean between steps so no stray grit travels with the dough.",
    "Loosen the pan juices with a splash of hot water and pour them back over everything.",
]

SERVINGS_ORIGINAL = [1, 2, 3, 4, 6]
SERVINGS_TARGET = [2, 4]


def _rotate(items: list, offset: int) -> list:
    return items[offset % len(items):] + items[: offset % len(items)]


def _synthetic_title(i: int) -> str:
    # Coprime strides over the three pools (periods 20/30/23 -> lcm 1380)
    # keep every title in 0..151 distinct while varying all three words.
    adjective = TITLE_ADJECTIVES[(i * 7) % len(TITLE_ADJECTIVES)]
    core = TITLE_CORES[(i * 11) % len(TITLE_CORES)]
    form = TITLE_FORMS[(i * 17) % len(TITLE_FORMS)]
    return f"{adjective} {core} {form}"


def _amount_text(name: str, amount: int | None, unit: str | None, prep: list[str]) -> str:
    if amount is None and unit is None:
        text = f"{name} to taste"
    elif amount is None and unit is not None:
        text = f"a {unit} of {name}"
    else:
        text = f"{amount} {unit} {name}"
    if prep:
        text += f", {prep[0]}"
    return text


def _synthetic_record(i: int, url_slug: str, ingredient_range: tuple[int, int], step_range: tuple[int, int]) -> dict:
    title = _synthetic_title(i)
    servings_original = SERVINGS_ORIGINAL[i % len(SERVINGS_ORIGINAL)]
    servings_target = SERVINGS_TARGET[i % len(SERVINGS_TARGET)]
    lo, hi = ingredient_range
    ingredient_count = lo + (i * 5) % (hi - lo + 1)
    rotated = _rotate(INGREDIENT_ITEMS, i)
    ingredients: list[dict] = []
    for j, (name, unit, amount) in enumerate(rotated[:ingredient_count]):
        prep: list[str] = []
        if (i + j) % 3 == 0:
            prep = [PREP_ACTIONS[(i + j) % len(PREP_ACTIONS)]]
        if (i + j) % 5 == 0:
            amount_value, amount_unit = None, None
            scaled_amount = None
        elif (i + j) % 7 == 3:
            amount_value, amount_unit = None, "pinch"
            scaled_amount = None
        else:
            amount_value, amount_unit = amount, unit
            scale = servings_target / servings_original
            scaled_amount = max(1, round(amount * scale)) if amount is not None else None
        raw = _amount_text(name, amount_value, amount_unit, prep)
        scaled = _amount_text(name, scaled_amount, amount_unit, prep)
        ingredients.append(
            {
                "raw": raw,
                "scaled_raw": scaled,
                "name": name,
                "amount_value": amount_value,
                "amount_unit": amount_unit,
                "prep_actions": prep,
            }
        )
    lo, hi = step_range
    step_count = lo + (i * 11) % (hi - lo + 1)
    steps = _rotate(STEP_SENTENCES, i * 5)[:step_count]
    return {
        "title": title,
        "source_url": f"https://example.com/fixtures/{url_slug}",
        "servings_original": servings_original,
        "servings_target": servings_target,
        "ingredients": ingredients,
        "steps": steps,
        "synthetic": True,
    }


def _bundled_titles() -> set[str]:
    payload = json.loads(DATA_JSON.read_bytes())
    return {row[1].strip().lower() for row in payload["recipes"]}


def _validate(records: list[dict], expected: int, ingredient_range: tuple[int, int], step_range: tuple[int, int], bundled: set[str]) -> None:
    lo_i, hi_i = ingredient_range
    lo_s, hi_s = step_range
    seen_titles: set[str] = set()
    seen_urls: set[str] = set()
    for record in records:
        assert list(record.keys()) == RECORD_KEYS, f"record keys drifted: {list(record.keys())}"
        assert isinstance(record["title"], str) and record["title"]
        assert isinstance(record["source_url"], str) and record["source_url"].startswith("https://example.com/")
        assert isinstance(record["servings_original"], int) and record["servings_original"] > 0
        assert isinstance(record["servings_target"], int) and record["servings_target"] > 0
        assert record["synthetic"] is True
        assert lo_i <= len(record["ingredients"]) <= hi_i
        assert lo_s <= len(record["steps"]) <= hi_s
        for step in record["steps"]:
            assert isinstance(step, str) and step
        for ingredient in record["ingredients"]:
            assert list(ingredient.keys()) == INGREDIENT_KEYS
            assert isinstance(ingredient["name"], str) and ingredient["name"]
            assert isinstance(ingredient["raw"], str) and isinstance(ingredient["scaled_raw"], str)
            assert ingredient["amount_value"] is None or isinstance(ingredient["amount_value"], int)
            assert ingredient["amount_unit"] is None or isinstance(ingredient["amount_unit"], str)
            assert isinstance(ingredient["prep_actions"], list)
        title_key = record["title"].strip().lower()
        assert title_key not in bundled, f"fixture title collides with a bundled recipe: {record['title']}"
        assert title_key not in seen_titles, f"duplicate fixture title: {record['title']}"
        seen_titles.add(title_key)
        assert record["source_url"] not in seen_urls
        seen_urls.add(record["source_url"])
        blob = json.dumps(record).lower()
        assert "bbc" not in blob and "goodfood" not in blob, "forbidden token in synthetic record"
    assert len(records) == expected


def main() -> None:
    bundled = _bundled_titles()
    main_records = [
        _synthetic_record(i, f"synthetic-recipe-{i + 1:03d}", (4, 24), (1, 14))
        for i in range(MAIN_RECORDS)
    ]
    test_records = [
        _synthetic_record(i, f"synthetic-test-{i + 1:02d}", (8, 11), (1, 8))
        for i in range(TEST_RECORDS)
    ]
    _validate(main_records, MAIN_RECORDS, (4, 24), (1, 14), bundled)
    _validate(test_records, TEST_RECORDS, (8, 11), (1, 8), bundled)
    for path, records in ((MAIN_FIXTURE, main_records), (TEST_FIXTURE, test_records)):
        payload = json.dumps(records, indent=2, ensure_ascii=False) + "\n"
        path.write_bytes(payload.encode("utf-8"))
        print(f"wrote {path.relative_to(REPO_ROOT)} ({len(records)} synthetic records)")


if __name__ == "__main__":
    main()
