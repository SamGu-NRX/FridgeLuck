#!/usr/bin/env python3
"""Curated Open Images class sets for nonfood-rejection-v1.

All sets use Open Images boxable class MIDs (class-descriptions-boxable.csv,
601 classes). The sets are pinned constants so the frozen manifest is
reproducible without network access; sample.py asserts every MID exists in
the downloaded class-descriptions CSV before using it.

Set semantics (documented in METHOD.md):
  FOOD      visible food or drink evidence. ANY positive label from this set
            (human-verified, or machine-generated at confidence >= FOOD_POS_T)
            disqualifies an image from acting as a negative.
  CONTEXT   kitchen-relevant scene classes. A negative needs at least one so
            the scene is kitchen-relevant, not an arbitrary photo.
  OCCLUDER  classes whose contents the camera cannot see (closed boxes,
            opaque containers, sealed packaging). These split negatives into
            empty_visible (no occluder) and opaque_unknown (>=1 occluder).

MID provenance: manually read from class-descriptions-boxable.csv (v5/v6
boxable vocabulary). The lists are intentionally explicit rather than regex
generated so a re-run cannot silently drift.
"""

from __future__ import annotations

# Human-verified-positive threshold for machine labels on the FOOD side.
FOOD_POS_T = 0.7
# Machine food label threshold that DISQUALIFIES an image from being a
# negative (any food trace at this level makes "no food visible" unsafe).
NEG_FOOD_T = 0.5
# Machine evidence in [AMBIG_LOW, NEG_FOOD_T) on a kitchen-relevant image is
# recorded as ambiguous, not as a clean negative or clean food control.
AMBIG_LOW = 0.3
# Machine context/occluder evidence threshold.
CTX_MACH_T = 0.7
OCC_MACH_T = 0.5

FOOD = {
    "/m/02xwb": "Fruit",
    "/m/0f4s2w": "Vegetable",
    "/m/014j1m": "Apple",
    "/m/09qck": "Banana",
    "/m/0hqkz": "Grapefruit",
    "/m/09k_b": "Lemon",
    "/m/0cyhj_": "Orange",
    "/m/0fp6w": "Pineapple",
    "/m/0fbw6": "Cabbage",
    "/m/09728": "Bread",
    "/m/01fb_0": "Bagel",
    "/m/0fszt": "Cake",
    "/m/0270h": "Dessert",
    "/m/01nkt": "Cheese",
    "/m/0284d": "Dairy",
    "/m/033cnk": "Egg",
    "/m/01_bhs": "Fast food",
    "/m/0cdn1": "Hamburger",
    "/m/01dwwc": "Pancake",
    "/m/0663v": "Pizza",
    "/m/0l515": "Sandwich",
    "/m/06pcq": "Submarine sandwich",
    "/m/06nwz": "Seafood",
    "/m/01ww8y": "Snack",
    "/m/07j87": "Tomato",
    "/m/0271t": "Drink",
    "/m/04zpv": "Milk",
    "/m/02wbm": "Food",
    "/m/05z55": "Pasta",
    "/m/021mn": "Cookie",
    "/m/0jy4k": "Doughnut",
    "/m/0cxn2": "Ice cream",
    "/m/01hrv5": "Popcorn",
    "/m/081qc": "Wine",
    "/m/01599": "Beer",
    "/m/02vqfm": "Coffee",
    "/m/07clx": "Tea",
    "/m/0388q": "Grape",
    "/m/0dj6p": "Peach",
    "/m/061_f": "Pear",
    "/m/0kpqd": "Watermelon",
    "/m/07fbm7": "Strawberry",
    "/m/0fj52s": "Carrot",
    "/m/0hkxq": "Broccoli",
}

CONTEXT = {
    "/m/040b_t": "Refrigerator",
    "/m/0642b4": "Cupboard",
    "/m/01s105": "Cabinetry",
    "/m/04y4h8h": "Bathroom cabinet",
    "/m/0h8n5zk": "Kitchen & dining room table",
    "/m/0h99cwc": "Kitchen appliance",
    "/m/03_wxk": "Kitchenware",
    "/m/0b3fp9": "Countertop",
    "/m/0gjbg72": "Shelf",
    "/m/04kkgm": "Bowl",
    "/m/03hj559": "Mixing bowl",
    "/m/0h8n27j": "Serving tray",
    "/m/02pdsw": "Cutting board",
    "/m/03hlz0c": "Kitchen utensil",
    "/m/058qzx": "Kitchen knife",
    "/m/0fx9l": "Microwave oven",
    "/m/02tsc9": "Slow cooker",
    "/m/04v6l4": "Frying pan",
    "/m/03s_tn": "Kettle",
    "/m/01k6s3": "Toaster",
    "/m/07xyvk": "Coffeemaker",
}

OCCLUDER = {
    "/m/025dyy": "Box",
    "/m/011q46kg": "Container",
    "/m/05gqfk": "Plastic bag",
    "/m/04dr76w": "Bottle",
    "/m/02jnhm": "Tin can",
}

# Names are re-derived and checked against class-descriptions at build time.
FOOD_NAMES = set(FOOD.values())
CONTEXT_NAMES = set(CONTEXT.values())
OCCLUDER_NAMES = set(OCCLUDER.values())

STRATA = ("empty_visible", "opaque_unknown", "food_control")
ROLES = ("negative", "food_control")
