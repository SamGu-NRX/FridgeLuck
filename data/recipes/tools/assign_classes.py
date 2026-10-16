#!/usr/bin/env python3
"""Assign composition classes to the vocabulary's unknown keys (burst9).

Every formerly-unknown vocabulary key gains a real class where a source
supports one, in priority order:

1. CURATED — an explicit per-key entry below, each with a one-line reason.
2. The suite-C allergen table (data/recipes/suite/allergens.json), matched on
   the key's name or aliases; its FSIS-fine classes map onto the vocabulary's
   coarse set (meat_* -> meat, flesh_fish -> fish, ...).
3. The food-safety classifier's pinned FSIS name patterns
   (food_safety._CLASS_PATTERNS) applied to the key's surface name — the repo's
   own reviewed name->animal-class table. UNCHARTED animal foods (venison,
   goat, offal) still carry class `meat` (or `fish`/`shellfish`): the chart has
   no doneness row for them, but their composition is not in doubt.
4. The bundled catalog's FDC `food_category` for the key's fdc_id, for the
   categories that determine the class unambiguously (Vegetables -> plant,
   Poultry Products -> meat, Cheese -> dairy, ...). Ambiguous categories
   (Finfish AND Shellfish, Dairy AND Egg, Cereal Grains, Nut and Seed, Fats
   and Oils, soups/sauces, mixed dishes) are never auto-assigned.

After the class is chosen, composition.py's LABEL_DEPENDENT table applies a
fail-closed `unknown` marker to keys whose surface it flags ("stock may
contain meat, milk or wheat"): the class list records what is certain plus
`unknown` for the may-vary part, matching the beef_stock precedent. `unknown`
blocks every allergen and diet check, which is exactly the may-contain case.

Each changed entry records `class_source` naming the source and reason. A key
with no source stays `unknown` — never guessed — with a class_source saying
why. Deterministic: same inputs -> byte-identical output.

Run order: build_vocab.py first (it owns identity and nutrition), then this
tool; a future vocabulary revision replays both.
"""
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "data/recipes/tools"))

from pipeline.normalize import normalize_name  # noqa: E402
import composition  # noqa: E402
import food_safety  # noqa: E402

VOCAB = REPO / "data/ingredients/vocabulary.json"
CATALOG = REPO / "apps/ios/Resources/usda_ingredient_catalog.sqlite"
ALLERGENS = REPO / "data/recipes/suite/allergens.json"

# FSIS-fine classes -> the vocabulary's coarse composition classes. Both the
# suite allergen table and the food-safety classifier use these names.
ALLERGEN_CLASS_MAP = {
    "meat_poultry": "meat", "meat_ground": "meat",
    "meat_whole_cut_pork": "meat", "meat_whole_cut_red": "meat",
    "flesh_fish": "fish", "fish": "fish",
    "flesh_shellfish": "shellfish", "shellfish": "shellfish",
    "egg": "egg", "dairy": "dairy", "gluten": "gluten", "honey": "honey",
    "soy": "soy", "peanut": "peanut", "sesame": "sesame", "tree_nut": "tree_nut",
    # animal_product alone says "animal-derived" without naming the class;
    # every such entry in the table is a stock, and the curated stock rule
    # (or the LABEL_DEPENDENT overlay) classes it better. Skip it here.
}

# FDC food categories whose composition the category pins unambiguously.
# Everything not listed here is ambiguous by category alone (Dairy AND Egg,
# Finfish AND Shellfish, Cereal Grains across wheat and rice, Nut and Seed
# across peanut and tree nut, Fats and Oils across butter and olive oil,
# soups/sauces/mixed dishes compound by nature) and needs a named source.
FDC_CATEGORY_CLASSES = {
    "Vegetables and Vegetable Products": "plant",
    "Other vegetables and combinations": "plant",
    "Tomatoes": "plant",
    "Onions": "plant",
    "Cabbage": "plant",
    "Other red and orange vegetables": "plant",
    "Other starchy vegetables": "plant",
    "Olives, pickles, pickled vegetables": "plant",
    "French fries and other fried white potatoes": "plant",
    "Fruits and Fruit Juices": "plant",
    "Blueberries and other berries": "plant",
    "Citrus juice": "plant",
    "Mango and papaya": "plant",
    "Pineapple": "plant",
    "Apple juice": "plant",
    "Legumes and Legume Products": "plant",
    "Beans, peas, legumes": "plant",
    "Rice": "plant",
    "Spices and Herbs": "plant",
    "Beverages": "plant",
    "Coffee": "plant",
    "Tea": "plant",
    "Poultry Products": "meat",
    "Chicken, whole pieces": "meat",
    "Beef Products": "meat",
    "Beef, excludes ground": "meat",
    "Pork Products": "meat",
    "Pork": "meat",
    "Bacon": "meat",
    "Sausages and Luncheon Meats": "meat",
    "Sausages": "meat",
    "Lamb, Veal, and Game Products": "meat",
    "Lamb, goat, game": "meat",
    "Fish": "fish",
    "Cheese": "dairy",
    "Yogurt, regular": "dairy",
    "Cream and cream substitutes": "dairy",
    "Ice cream and frozen dairy desserts": "dairy",
    "Cottage/ricotta cheese": "dairy",
}

# Curated classes for the keys no table above can class honestly, each with a
# one-line reason recorded in class_source. Also used to override noisy FDC
# pins (the bundled catalog's food_category has miscategories: steak under
# vegetables, cinnamon under baked products).
CURATED: dict[str, tuple[list[str], str]] = {
    # mustard is an onboarding allergen group (milk, egg, peanut, tree_nut,
    # soy, wheat_gluten, fish, shellfish, sesame, mustard)
    "mustard": (["mustard"], "mustard seeds and prepared mustard; an onboarding allergen group"),
    # stocks and broths: name-supported class + composition.py's may-contain
    "beef_vegetable_stock": (["meat", "unknown"], "beef in the name; stock varies by product"),
    "chicken_stock": (["meat", "unknown"], "chicken in the name; stock may contain milk or wheat"),
    "broth": (["unknown"], "composition.py: stock/broth may contain meat, milk or wheat"),
    "stock": (["unknown"], "composition.py: stock/broth may contain meat, milk or wheat"),
    "dashi": (["unknown"], "may be kombu-only (vegan) or bonito-based (fish); product-dependent"),
    # pastes and sauces the composition gate flags or that vary by product
    "black_bean_paste": (["soy", "unknown"], "fermented soybean paste; some products add wheat flour"),
    "doenjang": (["soy", "unknown"], "fermented soybean paste; some products blend barley or wheat"),
    "doubanjiang": (["soy", "unknown"], "fermented chili-soy paste; some products add wheat flour"),
    "hoisin": (["soy", "unknown"], "composition.py's compound scan flags hoisin for gluten"),
    "tamari": (["soy", "unknown"], "composition.py: some tamari contains wheat"),
    "hao_you": (["soy", "gluten"], "soy sauce is brewed from soybeans and wheat"),
    "green_curry_paste": (["unknown"], "Thai curry pastes commonly contain shrimp paste or fish sauce"),
    "massaman_curry_paste": (["unknown"], "Thai curry pastes commonly contain shrimp paste or fish sauce"),
    "mild_curry_powder": (["plant", "unknown"], "composition.py: curry powder may contain wheat flour"),
    "chipotle": (["plant", "unknown"], "composition.py: some chipotles in adobo contain wheat flour"),
    "baking_powder": (["plant", "unknown"], "composition.py: some baking powders use wheat starch"),
    "sriracha": (["plant"], "chili-garlic-vinegar sauce; no flagged product variation"),
    "chilli_sauce": (["plant"], "chili-vinegar-sugar sauce; no flagged product variation"),
    "hummus": (["plant", "sesame"], "chickpea-tahini dip; sesame from tahini"),
    "kimchi": (["plant", "unknown"], "kimchi often contains fish sauce; product-dependent"),
    "zaatar": (["plant", "sesame"], "thyme-sumac-sesame blend; sesame is a standard ingredient"),
    "harissa": (["plant"], "chili-spice paste in oil; no flagged product variation"),
    "black_vinegar": (["plant", "unknown"], "Chinese black vinegar is often brewed with wheat bran"),
    # dairy by name where the FDC pin is noisy or the category is ambiguous
    "condensed_milk": (["dairy"], "milk in the name (the catalog pin miscategorises it)"),
    "evaporated_milk": (["dairy"], "milk in the name; Dairy-and-Egg category is ambiguous"),
    "whipping_cream": (["dairy"], "cream in the name; Dairy-and-Egg category is ambiguous"),
    "labneh": (["dairy"], "strained yogurt"),
    "vanilla_ice_cream": (["dairy", "unknown"], "dairy dessert; egg custard bases vary"),
    "queso_fresco": (["dairy"], "cheese"),
    "cottage_cheese": (["dairy"], "cheese"),
    # grains: wheat vs gluten-free is a per-key fact the category cannot pin
    "bulgur": (["gluten"], "cracked wheat"),
    "semolina": (["gluten"], "durum wheat"),
    "noodles": (["gluten", "unknown"], "wheat noodles; dried pasta may contain egg"),
    "udon_noodles": (["gluten", "unknown"], "wheat noodles; may contain egg"),
    "pasta": (["gluten", "unknown"], "wheat pasta; dried pasta may contain egg"),
    "rice_noodles": (["plant"], "rice starch"),
    "glass_noodles": (["plant"], "mung-bean starch"),
    "sweet_potato_noodles": (["plant"], "sweet-potato starch"),
    "rice_flour": (["plant"], "rice"),
    "rice_powder": (["plant"], "toasted ground rice"),
    "masa_harina": (["plant"], "nixtamalized corn"),
    "cornstarch": (["plant"], "corn starch"),
    "quinoa": (["plant"], "pseudo-grain"),
    "millet": (["plant"], "gluten-free grain"),
    "millet_flour": (["plant"], "gluten-free grain"),
    "glutinous_rice": (["plant"], "rice"),
    # breads and wrappers: gluten certain on wheat products, may-contain unknown
    "baguette": (["gluten", "unknown"], "wheat bread; may contain milk, egg or lard"),
    "pitta": (["gluten", "unknown"], "wheat bread; may contain milk, egg or lard"),
    "flour_tortillas": (["gluten", "unknown"], "wheat tortillas; may contain milk, egg or lard"),
    "taco_shells": (["plant", "unknown"], "corn shells; some products fry in or add lard"),
    "spring_roll_wrappers": (["gluten", "unknown"], "wheat-flour wrappers; rice-paper variants exist"),
    "rice_paper": (["plant"], "rice-paper sheets"),
    "rice_cakes": (["plant"], "puffed rice"),
    "french_fries": (["plant", "unknown"], "fried; some venues and products use animal-fat fryers"),
    # nuts and seeds
    "walnuts": (["tree_nut", "plant"], "tree nut"),
    "egusi_seeds": (["plant"], "melon seeds"),
    "coconut": (["plant", "tree_nut"], "composition.py's nut-free scan treats coconut as a nut; FDA labels it a tree nut"),
    # sweets: composition.py's sugar rule (bone-char refining) blocks vegan
    "sugar": (["plant", "unknown"], "composition.py: cane sugar may be refined with bone char"),
    "brown_sugar": (["plant", "unknown"], "composition.py: cane sugar may be refined with bone char"),
    "molasses": (["plant", "unknown"], "cane refining; composition.py's sugar rule"),
    "maple_syrup": (["plant"], "maple sap; not bone-char refined cane sugar"),
    "apricot_jam": (["plant", "unknown"], "fruit jam; some jellies use gelatin"),
    # drinks
    "red_wine": (["plant"], "grape wine; composition.py's claim gate does not treat wine as animal-derived"),
    "rum": (["plant"], "distilled from sugarcane molasses"),
    "rice_vinegar": (["plant"], "rice wine vinegar"),
    "water": (["mineral"], "plain water; no organic composition"),
    "yeast": (["plant"], "microbial fungus; carries no animal or gluten risk"),
    # produce and herbs the tables above cannot class
    "ackee": (["plant"], "fruit"),
    "artichoke_hearts": (["plant"], "vegetable"),
    "callaloo_greens": (["plant"], "leafy green"),
    "basil": (["plant"], "herb"),
    "chives": (["plant"], "herb"),
    "parsley": (["plant"], "herb"),
    "galangal": (["plant"], "rhizome"),
    "gochugaru": (["plant"], "chili flakes"),
    "kaffir_lime": (["plant"], "citrus leaf and fruit"),
    "preserved_lemon": (["plant"], "pickled lemon"),
    "scotch_bonnet": (["plant"], "chili"),
    "sichuan_peppercorns": (["plant"], "peppercorn"),
    "star_anise": (["plant"], "spice"),
    "sumac": (["plant"], "spice"),
    "thai_chilies": (["plant"], "chili"),
    "umeboshi": (["plant"], "pickled plum"),
    "five_spice_powder": (["plant"], "whole-spice blend; no wheat in the standard blend"),
    # meats the classifier calls UNCHARTED (no FSIS doneness row) but whose
    # composition is not in doubt
    "goat_meat": (["meat"], "animal flesh; uncharted for FSIS doneness, composition class is meat"),
    "chicharrones": (["meat"], "fried pork belly skin"),
    # noisy FDC pins overridden by the food itself
    "cinnamon": (["plant"], "spice; the bundled catalog's food_category pin is a miscategory"),
    "steak": (["meat"], "beef cut; the bundled catalog's food_category pin is a miscategory"),
    # fell through the first pass: ambiguous categories (Cereal Grains, Fats
    # and Oils) and noisy pins no other table covers
    "rice": (["plant"], "rice grain; Cereal Grains and Pasta spans wheat and rice"),
    "lemon_juice": (["plant"], "lemon juice; the catalog pins it under condiments"),
    "mirin": (["plant"], "sweet rice wine"),
    "olives": (["plant"], "olive fruit; Fats and Oils spans butter and plant oils"),
    "oranges": (["plant"], "citrus fruit; the bundled catalog's food_category pin is a miscategory"),
    "potato_starch": (["plant"], "potato starch"),
    "red_palm_oil": (["plant"], "pressed palm fruit; Fats and Oils spans butter and plant oils"),
    "green_papaya": (["plant"], "unripe papaya"),
}

# Keys the onboarding allergen groups name whose class set gains `mustard`:
# the vocabulary had them classed as their food (plant) but never as the
# allergen the app screens for.
MUSTARD_KEYS = {"mustard"}


def surface_names(entry: dict) -> list[str]:
    """The key and its surface names, normalized, most specific first."""
    names = [entry["key"].replace("_", " "), entry["display_name"],
             *entry.get("aliases", [])]
    seen: list[str] = []
    for n in names:
        low = normalize_name(n)
        if low and low not in seen:
            seen.append(low)
    return seen


def classifier_class(entry: dict) -> tuple[list[str], str] | None:
    """Composition class from the pinned FSIS name patterns (raw name match:
    the doneness gate strips canned/stock names first, but canned tuna is
    still fish for composition)."""
    for name in surface_names(entry):
        if food_safety.ingredient_class(name) == food_safety.UNCHARTED:
            return (["meat"], f"food-safety classifier: {name!r} is an animal food "
                             "with no FSIS row; composition class is meat")
        for pattern, cls in food_safety._CLASS_PATTERNS:
            if pattern.search(name):
                vocab = ALLERGEN_CLASS_MAP.get(cls)
                if vocab:
                    return ([vocab], f"food-safety classifier: {name!r} -> FSIS class {cls}")
    return None


def allergen_class(entry: dict, by_alias: dict[str, set[str]]) -> tuple[list[str], str] | None:
    for name in surface_names(entry):
        classes = by_alias.get(name)
        if classes:
            mapped = sorted({ALLERGEN_CLASS_MAP[c] for c in classes
                             if c in ALLERGEN_CLASS_MAP})
            if mapped:
                return (mapped, f"suite allergens.json: {name!r} classes "
                                f"{sorted(classes)}")
    return None


def fdc_class(entry: dict, fdc_category: dict[int | None, str | None]) -> tuple[list[str], str] | None:
    cat = fdc_category.get(entry.get("fdc_id"))
    if cat and cat in FDC_CATEGORY_CLASSES:
        return ([FDC_CATEGORY_CLASSES[cat]], f"fdc-category: {cat!r} "
                f"(fdc_id {entry.get('fdc_id')})")
    return None


def label_dependent_overlay(entry: dict, classes: list[str]) -> list[str]:
    """composition.py's LABEL_DEPENDENT reasons add a fail-closed `unknown`
    marker to the may-vary part of a key whose surface they flag."""
    names = " | ".join(surface_names(entry))
    for pattern, _blocked, why in composition.LABEL_DEPENDENT:
        if pattern.search(names) and "unknown" not in classes:
            return classes + ["unknown"]
    return classes


def main() -> None:
    doc = json.loads(VOCAB.read_text())
    entries = doc["entries"]

    table = json.loads(ALLERGENS.read_text())
    by_alias: dict[str, set[str]] = {}
    for name, rec in table["ingredients"].items():
        by_alias.setdefault(normalize_name(name), set()).update(rec.get("classes", []))

    con = sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
    fdc_category = {int(fid): cat for fid, cat in con.execute(
        "SELECT fdc_id, food_category FROM ingredient_catalog")}
    con.close()

    changed = 0
    sourced = 0
    for e in entries:
        if e.get("classes") and e["classes"] != ["unknown"]:
            if e["key"] in MUSTARD_KEYS and "mustard" not in e["classes"]:
                e["classes"] = e["classes"] + ["mustard"]
                e["class_source"] = "curated: mustard is an onboarding allergen group; " \
                                    "added to the existing food class"
                changed += 1
            continue  # already curated by build_vocab's CLASS_OVERRIDES
        changed += 1
        hit = None
        if e["key"] in CURATED:
            classes, reason = CURATED[e["key"]]
            hit = (classes, f"curated: {reason}")
        if hit is None:
            hit = allergen_class(e, by_alias)
        if hit is None:
            hit = classifier_class(e)
        if hit is None:
            hit = fdc_class(e, fdc_category)
        if hit is None:
            cat = fdc_category.get(e.get("fdc_id"))
            e["class_source"] = (
                f"unsourced: fdc-category {cat!r} is ambiguous, no allergen-table "
                "entry, no curated evidence — stays unknown (never guessed)")
            continue
        classes, source = hit
        classes = label_dependent_overlay(e, classes)
        e["classes"] = classes
        e["class_source"] = source
        e["class_note"] = "; ".join(filter(None, [
            e.get("class_note", "").replace(
                "no curated class — defaults to unknown (claim-blocking)", "").strip(" ;"),
            "unknown marker: composition may vary by product" if "unknown" in classes else "",
        ])) or e.get("class_note")
        sourced += 1

    doc.setdefault("sources", {})["classes"] = (
        "assign_classes.py: curated table, suite allergens.json, food-safety "
        "classifier patterns, and decisive FDC food_category rows; every "
        "changed entry records class_source, unsourceable keys stay unknown")

    VOCAB.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")

    still_unknown = [e["key"] for e in entries
                     if not e.get("classes") or e["classes"] == ["unknown"]]
    print(f"reviewed {changed} unknown keys; assigned classes to {sourced}")
    print(f"still unknown ({len(still_unknown)}): {', '.join(still_unknown)}")


if __name__ == "__main__":
    main()
