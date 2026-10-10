#!/usr/bin/env python3
"""Generates the frozen eval corpus for the unified-search eval harness.

Deterministic: same input -> byte-identical corpus.json. The output is
committed; this script documents provenance and can regenerate it.

Corpus shape (mirrors SearchDocument fields):
  kitchenIngredient: title/keywords/aliases/category
  kitchenInventory:  title/location/grams/expiry  (canonical id = "<ing>_<loc>")
  recipe:            title/keywords/created_at
  journal:           title/rating/cooked_at

Queries: 9 single-token, 4 multi-token, 7 date. Expected sets are hand-written
(no self-fulfilling match rules) and pinned below.
"""
import json
import os
import calendar

# ---------- ingredients (24) ----------
INGREDIENTS = [
    (1, "Chicken Breast", ["chicken"], "protein"),
    (2, "Whole Egg", ["eggs"], "protein"),
    (3, "Whole Milk", ["milk"], "dairy"),
    (4, "Butter", [], "dairy"),
    (5, "Cheddar Cheese", ["cheddar"], "dairy"),
    (6, "Greek Yogurt", ["yogurt"], "dairy"),
    (7, "Soy Sauce", [], "condiment"),
    (8, "Olive Oil", [], "condiment"),
    (9, "Garlic", [], "produce"),
    (10, "Yellow Onion", ["onion"], "produce"),
    (11, "Tomato", ["tomatoes"], "produce"),
    (12, "Spinach", [], "produce"),
    (13, "Mushrooms", [], "produce"),
    (14, "Bell Pepper", [], "produce"),
    (15, "Jasmine Rice", ["rice"], "pantry"),
    (16, "Dried Pasta", ["pasta"], "pantry"),
    (17, "Canned Chickpeas", ["chickpeas"], "pantry"),
    (18, "Flour Tortillas", ["tortillas"], "pantry"),
    (19, "Salmon Fillet", ["salmon"], "protein"),
    (20, "Chives", [], "herbs"),
    (21, "Maple Syrup", [], "condiment"),
    (22, "Aubergine", ["eggplant"], "produce"),
    (23, "Courgette", ["zucchini"], "produce"),
    (24, "Cilantro", ["coriander"], "herbs"),
]

# ---------- inventory (9) ----------
# (row_id, title, location, grams, expiry or None)  canonical id = "<row>_<loc>"
INVENTORY = [
    (1, "Chicken Breast", "fridge", 350, "2026-10-13"),
    (2, "Ground Beef", "fridge", 400, "2026-10-12"),
    (3, "Whole Milk", "fridge", 900, "2026-10-20"),
    (4, "Butter", "fridge", 250, "2026-11-01"),
    (5, "Spinach", "fridge", 150, "2026-10-11"),
    (6, "Tomato", "fridge", 300, "2026-10-14"),
    (7, "Jasmine Rice", "pantry", 2000, None),
    (8, "Dried Pasta", "pantry", 900, None),
    (9, "Canned Chickpeas", "pantry", 400, None),
]

# ---------- recipes (30) ----------
RECIPES = [
    (1, "Garlic Butter Chicken", "chicken breast butter garlic", "2026-04-02"),
    (2, "Lemon Herb Chicken", "chicken lemon olive oil", "2026-04-02"),
    (3, "Chicken Noodle Soup", "chicken pasta onion garlic", "2026-04-03"),
    (4, "Creamy Tomato Pasta", "pasta tomato garlic milk", "2026-04-03"),
    (5, "Pesto Pasta Salad", "pasta spinach olive oil", "2026-04-05"),
    (6, "Mushroom Risotto", "rice mushrooms onion butter", "2026-04-06"),
    (7, "Egg Fried Rice", "rice egg soy sauce chives", "2026-04-06"),
    (8, "Salmon Teriyaki", "salmon soy sauce maple syrup", "2026-04-08"),
    (9, "Baked Salmon Fillet", "salmon olive oil garlic", "2026-04-08"),
    (10, "Cheese Quesadilla", "tortillas cheddar butter", "2026-04-10"),
    (11, "Spinach Frittata", "egg spinach cheddar", "2026-04-11"),
    (12, "Veggie Omelette", "egg bell pepper onion mushrooms", "2026-04-11"),
    (13, "Chili Con Carne", "beef tomato onion garlic", "2026-04-13"),
    (14, "Beef Stir Fry", "beef soy sauce bell pepper", "2026-04-13"),
    (15, "Vegetable Stir Fry", "bell pepper mushrooms soy sauce rice", "2026-04-15"),
    (16, "Chickpea Buddha Bowl", "chickpeas rice spinach", "2026-04-16"),
    (17, "Hummus Wrap", "chickpeas tortillas olive oil", "2026-04-17"),
    (18, "Eggplant Parmigiana", "eggplant tomato cheddar", "2026-04-18"),
    (19, "Ratatouille", "eggplant tomato bell pepper onion", "2026-04-19"),
    (20, "Zucchini Fritters", "zucchini egg olive oil", "2026-04-20"),
    (21, "Greek Salad", "tomato onion olive oil", "2026-04-21"),
    (22, "Garlic Mushrooms on Toast", "mushrooms butter garlic", "2026-04-22"),
    (23, "Maple Glazed Carrots", "maple syrup butter", "2026-04-23"),
    (24, "Butter Garlic Rice", "rice butter garlic", "2026-04-24"),
    (25, "Tomato Basil Soup", "tomato onion garlic", "2026-04-25"),
    (26, "Chicken Quesadilla", "chicken tortillas cheddar", "2026-04-26"),
    (27, "Beef Tacos", "beef tortillas tomato", "2026-04-27"),
    (28, "Soy Glazed Salmon Rice Bowl", "salmon soy sauce rice", "2026-04-28"),
    (29, "Spinach Garlic Pasta", "pasta spinach garlic", "2026-04-29"),
    (30, "Chive Egg Scramble", "egg chives butter", "2026-04-30"),
]

# ---------- journal (20) ----------
JOURNAL = [
    (1, "Chicken Noodle Soup", "2026-05-06", 4),
    (2, "Mushroom Risotto", "2026-05-18", 5),
    (3, "Egg Fried Rice", "2026-06-02", 3),
    (4, "Garlic Butter Chicken", "2026-06-09", 5),
    (5, "Creamy Tomato Pasta", "2026-06-21", 4),
    (6, "Salmon Teriyaki", "2026-07-04", 5),
    (7, "Spinach Frittata", "2026-07-11", 2),
    (8, "Chickpea Buddha Bowl", "2026-07-19", 3),
    (9, "Cheese Quesadilla", "2026-07-27", 1),
    (10, "Vegetable Stir Fry", "2026-08-02", 4),
    (11, "Chili Con Carne", "2026-08-08", 5),
    (12, "Chicken Noodle Soup", "2026-08-14", 3),
    (13, "Egg Fried Rice", "2026-08-14", 4),
    (14, "Mushroom Risotto", "2026-08-21", 4),
    (15, "Garlic Butter Chicken", "2026-08-29", 5),
    (16, "Creamy Tomato Pasta", "2026-09-05", 3),
    (17, "Salmon Teriyaki", "2026-09-12", 4),
    (18, "Chickpea Buddha Bowl", "2026-09-19", 2),
    (19, "Cheese Quesadilla", "2026-09-26", 3),
    (20, "Spinach Frittata", "2026-10-03", 5),
]

WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS = ["january", "february", "march", "april", "may", "june", "july",
          "august", "september", "october", "november", "december"]
MONTH_ABBR = [m[:3] for m in MONTHS]


def date_tokens(iso_day):
    y, m, d = (int(x) for x in iso_day.split("-"))
    return " ".join([
        "%04d-%02d-%02d" % (y, m, d), "%04d-%02d" % (y, m),
        "%04d" % y, "%02d" % d, MONTHS[m - 1], MONTH_ABBR[m - 1],
    ])


def pretty_date(iso_day):
    y, m, d = (int(x) for x in iso_day.split("-"))
    wd = WEEKDAYS[calendar.weekday(y, m, d)]
    return "%s, %s %02d, %d" % (wd, MONTHS[m - 1].capitalize(), d, y)


docs = []

for iid, title, aliases, category in INGREDIENTS:
    docs.append({
        "kind": "kitchen_ingredient",
        "canonicalID": "kitchen_ingredient:%d" % iid,
        "title": title,
        "subtitle": category,
        "keywords": " ".join(aliases),
        "dateTokens": "",
    })

for iid, title, location, grams, expiry in INVENTORY:
    docs.append({
        "kind": "kitchen_inventory",
        "canonicalID": "kitchen_inventory:%d_%s" % (iid, location),
        "title": title,
        "subtitle": "%s · %d g in stock" % (location, grams),
        "keywords": "inventory in stock kitchen",
        "dateTokens": date_tokens(expiry) if expiry else "",
    })

for rid, title, keywords, created in RECIPES:
    docs.append({
        "kind": "recipe",
        "canonicalID": "recipe:%d" % rid,
        "title": title,
        "subtitle": "30 min · 2 servings",
        "keywords": keywords,
        "dateTokens": date_tokens(created),
    })

for jid, title, cooked, rating in JOURNAL:
    docs.append({
        "kind": "journal",
        "canonicalID": "journal:%d" % jid,
        "title": title,
        "subtitle": "Cooked %s · rated %d" % (pretty_date(cooked), rating),
        "keywords": "journal meal logged",
        "dateTokens": date_tokens(cooked),
    })

# ---------- frozen queries (expected sets hand-written) ----------
QUERIES = [
    # single-token (8)
    {"q": "chicken", "expected": ["kitchen_ingredient:1", "kitchen_inventory:1_fridge",
                                  "recipe:1", "recipe:2", "recipe:3", "recipe:26"]},
    # aubergine matches only the ingredient title; the alias direction is
    # covered by "eggplant" (keywords), since engine-level aliasing lives in
    # the adapters' alias map, not in the corpus.
    {"q": "aubergine", "expected": ["kitchen_ingredient:22"]},
    {"q": "eggplant", "expected": ["kitchen_ingredient:22", "recipe:18", "recipe:19"]},
    {"q": "soy sauce", "expected": ["kitchen_ingredient:7", "recipe:7", "recipe:8",
                                    "recipe:14", "recipe:15", "recipe:28"]},
    {"q": "chickpeas", "expected": ["kitchen_ingredient:17", "kitchen_inventory:9_pantry",
                                    "recipe:16", "recipe:17"]},
    {"q": "pasta", "expected": ["kitchen_ingredient:16", "kitchen_inventory:8_pantry",
                                "recipe:3", "recipe:4", "recipe:5", "recipe:29"]},
    {"q": "cheddar", "expected": ["kitchen_ingredient:5", "recipe:10", "recipe:11",
                                  "recipe:18", "recipe:26"]},
    {"q": "spinach", "expected": ["kitchen_ingredient:12", "kitchen_inventory:5_fridge",
                                  "recipe:5", "recipe:11", "recipe:16", "recipe:29"]},
    {"q": "milk", "expected": ["kitchen_ingredient:3", "kitchen_inventory:3_fridge",
                               "recipe:4"]},
    # multi-token (4)
    {"q": "garlic chicken", "expected": ["recipe:1", "recipe:3"]},
    {"q": "tomato pasta", "expected": ["recipe:4"]},
    {"q": "spinach egg", "expected": ["recipe:11"]},
    {"q": "rice soy", "expected": ["recipe:7", "recipe:15", "recipe:28"]},
    # date (6)
    {"q": "june", "expected": ["journal:3", "journal:4", "journal:5"]},
    {"q": "july", "expected": ["journal:6", "journal:7", "journal:8", "journal:9"]},
    {"q": "2026-08-14", "expected": ["journal:12", "journal:13"]},
    # Bare "yyyy-mm" number queries are deliberately NOT frozen: the
    # dateTokens contain standalone day numbers ("08") and years ("2026"),
    # so prefix matching makes them ambiguous (an April 8 recipe matches
    # "2026-08"). Month names and full dates are the supported date queries.
    {"q": "august", "expected": ["journal:10", "journal:11", "journal:12",
                                 "journal:13", "journal:14", "journal:15"]},
    {"q": "september", "expected": ["journal:16", "journal:17", "journal:18",
                                    "journal:19"]},
    # october also matches fridge inventory expiring in October by design.
    {"q": "october", "expected": ["journal:20", "kitchen_inventory:1_fridge",
                                  "kitchen_inventory:2_fridge", "kitchen_inventory:3_fridge",
                                  "kitchen_inventory:5_fridge", "kitchen_inventory:6_fridge"]},
]

ids = set(d["canonicalID"] for d in docs)
missing = [e for query in QUERIES for e in query["expected"] if e not in ids]
assert not missing, "expected ids missing from corpus: %s" % missing

corpus = {
    "version": "unified-search-eval-corpus-v1",
    "counts": {"ingredients": len(INGREDIENTS), "inventory": len(INVENTORY),
               "recipes": len(RECIPES), "journal": len(JOURNAL)},
    "docs": docs,
    "queries": QUERIES,
}

output_path = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "Tests", "SearchCheckTests", "Fixtures", "corpus.json")
with open(output_path, "w") as f:
    json.dump(corpus, f, indent=1)
    f.write("\n")

print("docs: %d  queries: %d" % (len(docs), len(QUERIES)))
