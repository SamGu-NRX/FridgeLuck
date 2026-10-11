#!/usr/bin/env python3
"""Generate the ingredient-facts dataset (identities.json + facts.json) and
validate it. Stdlib only. Run: python3 tools/build_dataset.py

Curated table -> derived facts -> validation -> emission.
Evidence refs are real: USDA rows seen in apps/ios/Resources/usda_ingredient_catalog.sqlite,
recipe corpus paths on origin/fleet/fl-recipe-originals* branches, regulations,
or "standard" composition knowledge. Nothing is invented; absent facts are
omitted so evaluation fails closed.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # data/ingredient-facts
REPO = ROOT.parent.parent                              # repo checkout

ALLERGENS = ["milk", "egg", "fish", "crustaceanShellfish", "treeNuts",
             "peanuts", "wheat", "soy", "sesame"]
DIETS = ["vegetarian", "vegan", "pescatarian", "glutenFree", "dairyFree"]
CERTAINTIES = ["certain", "typical", "variable", "unknown"]
EVIDENCE_KINDS = ["usda", "label", "reference", "recipe", "standard"]
GLUTEN_GRAINS = {"wheat", "wheat-flour", "durum-wheat-flour", "barley",
                 "barley-malt", "rye-flour", "malt-vinegar"}

APP_LOCAL_IDS = {
    "egg": 1, "rice": 2, "soy-sauce": 3, "chicken-breast": 4, "onion": 5,
    "garlic": 6, "tomato": 7, "bell-pepper": 8, "pasta": 9, "potato": 10,
    "carrot": 11, "cheese": 12, "milk": 13, "butter": 14, "bread": 15,
    "olive-oil": 16, "lemon": 17, "mushroom": 18, "spinach": 19, "banana": 20,
    "green-onion": 21, "sesame-oil": 22, "tofu": 23, "broccoli": 24,
    "cucumber": 25, "avocado": 26, "black-beans": 27, "tortilla": 28,
    "lime": 29, "ginger": 30, "oats": 31, "yogurt": 32, "honey": 33,
    "corn": 34, "chickpeas": 35, "salmon": 36, "sweet-potato": 37,
    "ground-beef": 38, "lettuce": 39, "apple": 40, "peanut-butter": 41,
    "frozen-peas": 42, "canned-tuna": 43, "celery": 44, "zucchini": 45,
    "red-pepper-flakes": 46, "cumin": 47, "cilantro": 48, "coconut-milk": 49,
    "sour-cream": 50,
}

# ---------------------------------------------------------------------------
# Evidence constructors.

def ev(kind, ref=None, note=None):
    e = {"kind": kind}
    if ref is not None:
        e["ref"] = ref
    if note is not None:
        e["note"] = note
    return e


def usda(fdc, row, note="matched catalog row"):
    return ev("usda", f"fdc {fdc} '{row}'",
              f"apps/ios/Resources/usda_ingredient_catalog.sqlite row; {note}")


def f(state, kind, ref=None, note=None):
    return {"state": state, "evidence": ev(kind, ref, note)}


CLASS_DIETS = {
    "plant": ("allowed", "allowed", "allowed"),
    "fungus": ("allowed", "allowed", "allowed"),
    "mineral": ("allowed", "allowed", "allowed"),
    "meat": ("violated", "violated", "violated"),
    "fish": ("violated", "violated", "allowed"),
    "shellfish": ("violated", "violated", "allowed"),
    "dairy": ("allowed", "violated", "allowed"),
    "egg": ("allowed", "violated", "allowed"),
    "animal-derived": ("violated", "violated", "violated"),
    "insect-product": ("allowed", "violated", "allowed"),
}
CLASS_DIET_NOTE = {
    "plant": "plant food: no animal-derived components",
    "fungus": "fungal food: no animal-derived components",
    "mineral": "inorganic substance: no animal-derived components",
    "meat": "animal flesh; not compatible with vegetarian/vegan/pescatarian-excluding-flesh diets",
    "fish": "fin fish; pescatarian diets include fish, vegetarian/vegan do not",
    "shellfish": "shellfish; pescatarian diets include shellfish, vegetarian/vegan do not",
    "dairy": "dairy food: animal milk product; vegetarian yes, vegan no",
    "egg": "egg: vegetarian yes, vegan no",
    "animal-derived": "animal-derived ingredient; not vegetarian, vegan or pescatarian",
    "insect-product": "produced by bees (an animal); vegetarian yes, vegan no",
}

ENTRIES: list[dict] = []


def entry(**kw) -> dict:
    kw.setdefault("synonyms", [])
    kw.setdefault("contains", [])
    kw.setdefault("allergen_overrides", {})
    kw.setdefault("diet_overrides", {})
    kw.setdefault("components", None)
    kw.setdefault("composition_complete", None)
    kw.setdefault("forms", None)
    kw.setdefault("note", None)
    kw.setdefault("fdc", None)
    kw.setdefault("gluten", None)
    kw.setdefault("gluten_note", None)
    kw.setdefault("gluten_override", None)
    ENTRIES.append(kw)
    return kw


def part(key, display, cls=None, **kw):
    kw["kind"] = "part"
    return entry(key=key, display=display, cls=cls, **kw)


def simple(key, display, cls, **kw):
    kw["kind"] = "simple"
    return entry(key=key, display=display, cls=cls, **kw)


def compound(key, display, components, composition_complete=False, **kw):
    kw["kind"] = "compound"
    return entry(key=key, display=display, cls=None, components=components,
                 composition_complete=composition_complete, **kw)


def comp(key, certainty, evidence=None):
    c = {"key": key, "certainty": certainty}
    if evidence is not None:
        c["evidence"] = evidence
    return c


# ===========================================================================
# Component parts (facts-only; not resolvable identities)
# ===========================================================================

part("soybeans", "Soybeans", "plant", contains=["soy"],
     fdc=usda(169282, "Green Soybeans (Raw)", "closest catalog row; alt name 'edamame raw'"))
part("wheat", "Wheat", "plant", contains=["wheat"], gluten="contains",
     note="wheat grain: FDA major allergen wheat, and a gluten source")
part("wheat-flour", "Wheat flour", "plant", contains=["wheat"], gluten="contains",
     fdc=usda(169761, "All-Purpose Wheat Flour", "closest catalog row for generic wheat flour"))
part("durum-wheat-flour", "Durum wheat flour", "plant", contains=["wheat"], gluten="contains",
     note="dried pasta is milled durum wheat and water")
part("barley", "Barley", "plant", gluten="contains",
     note="barley carries gluten but is not wheat (no wheat-allergen crossover)")
part("barley-malt", "Barley malt", "plant", gluten="contains",
     note="malt syrup and malt vinegar derive from barley")
part("rye-flour", "Rye flour", "plant", gluten="contains",
     note="rye carries gluten but is not wheat")
part("oats", "Oats", "plant", gluten="unknown",
     gluten_note="oats are gluten-free by nature but routinely cross-contacted; certification varies",
     fdc=usda(168872, "Oat Bran (Raw)", "closest catalog row"))
part("rice", "Rice", "plant", fdc=usda(168877, "White Rice (Raw)", "catalog alt name 'uncooked white rice'"))
part("glutinous-rice", "Glutinous rice", "plant", note="sweet rice used for koji and gochujang")
part("rice-koji", "Rice koji (Aspergillus oryzae on rice)", "fungus",
     note="standard koji is grown on rice; barley koji (mugi) is a variant")
part("milk", "Milk", "dairy", contains=["milk"],
     fdc=usda(170871, "Milk (2% Reduced Fat)", "closest catalog row for plain milk"))
part("cream", "Cream", "dairy", contains=["milk"])
part("milk-powder", "Milk powder", "dairy", contains=["milk"])
part("egg", "Egg", "egg", contains=["egg"])
part("anchovy", "Anchovy", "fish", contains=["fish"])
part("pork", "Pork", "meat")
part("pork-fat", "Pork fat", "meat",
     fdc=usda(167813, "Pork Fat (Raw)", "rendered lard derives from pork fat"))
part("animal-collagen", "Animal collagen (skin, bones, connective tissue)", "animal-derived",
     note="gelatin source species (pork or beef) varies by product")
part("animal-rennet", "Animal rennet (calf stomach enzyme)", "animal-derived",
     note="traditional hard cheeses such as Parmigiano-Reggiano require calf rennet")
part("salt", "Salt", "mineral")
part("water", "Water", "mineral")
part("sugar", "Sugar", "plant",
     note="sucrose from cane or beet; vegan-ingredient-wise, though some refining uses bone char filtration")
part("molasses", "Molasses", "plant")
part("yeast", "Yeast", "fungus")
part("distilled-vinegar", "Distilled vinegar", "plant",
     note="distilled spirit vinegar; distillation removes gluten protein")
part("malt-vinegar", "Malt vinegar", "plant", gluten="contains",
     note="malt vinegar is brewed from barley; UK Worcestershire recipes use it, US ones distilled vinegar")
part("basil", "Basil", "plant")
simple("garlic", "Garlic", "plant", fdc=usda(169230, "Garlic (Raw)"))
simple("pine-nuts", "Pine nuts", "plant", contains=["treeNuts"],
       fdc=usda(170591, "Pine Nuts (Dried)"))
part("olive-oil", "Olive oil", "plant", fdc=usda(171413, "Olive Oil"))
part("lemon-juice", "Lemon juice", "plant", fdc=usda(167747, "Lemon Juice (Raw)"))
part("chili-peppers", "Chili peppers", "plant")
part("tomato", "Tomato", "plant", fdc=usda(170457, "Tomatoes (Red, Ripe, Raw)"))
part("onion", "Onion", "plant", fdc=usda(170000, "Onions (Raw)"))
part("cucumber", "Cucumber", "plant", fdc=usda(168409, "Cucumber (With Peel, Raw)"))
part("mint", "Mint", "plant")
part("parsley", "Parsley", "plant", fdc=usda(170416, "Parsley (Fresh)"))
part("spices", "Mixed spices", "plant",
     note="whole or ground single spices; anti-caking agents in jarred blends are the variable part")
part("anti-caking-agent", "Anti-caking agent (silicon dioxide etc.)", "mineral",
     note="jarred spice blends may add anti-caking agents; composition varies by brand")
part("mustard", "Mustard (seeds or prepared)", "plant",
     note="mustard is an EU-declared allergen but not one of the nine FDA major allergens")
part("vegetables-mixed", "Mixed vegetables", "plant")
part("chicken", "Chicken", "meat", fdc=usda(171052, "Chicken (Meat Only, Raw)"))
part("chickpeas", "Chickpeas", "plant", fdc=usda(2644282, "Chickpeas (Dry)"))
part("tahini", "Tahini (sesame paste)", "plant", contains=["sesame"],
     fdc=usda(170191, "Sesame Butter (Tahini)"))
part("soybean-oil-refined", "Refined soybean oil", "plant",
     note="refined soybean oil is exempt from US soy allergen labeling (FDA FALCPA exemption; protein removed)")
part("rapeseed-oil", "Rapeseed (canola) oil", "plant")
part("sunflower-oil", "Sunflower oil", "plant")
part("palm-oil", "Palm oil", "plant")
part("corn-starch-modified", "Modified corn starch", "plant")
part("caramel-colour", "Caramel colour", "plant")
part("monosodium-glutamate", "Monosodium glutamate (flavour enhancer)", "mineral")
part("flavourings-unknown", "Flavourings and spice extracts (source varies)", "mineral",
     note="commercial stock cubes list unspecific flavourings; sources vary by brand")
part("hydrolysed-plant-protein", "Hydrolysed plant protein (source varies)", "plant",
     note="may derive from soy, wheat, maize or rice depending on brand")
part("milk-derivatives", "Milk derivatives (some brands)", "dairy", contains=["milk"],
     note="some stock cube and bread brands include whey or lactose")
part("fat-source-varies", "Fat (source varies by brand)", "plant",
     note="stock cube fat may be vegetable or animal, including lard in some brands")
part("celery-part", "Celery", "plant", fdc=usda(169988, "Celery (Raw)"),
     note="celery is an EU-declared allergen but not one of the nine FDA major allergens")
part("distilled-spirit", "Distilled spirit (shochu)", "plant",
     note="distillation removes gluten protein even when brewed from barley")
part("lactic-cultures", "Lactic acid cultures", "fungus")
part("food-acid", "Food acid (lemon juice or vinegar)", "plant")
part("napa-cabbage", "Napa cabbage", "plant")
part("gochugaru", "Gochugaru (Korean chili flakes)", "plant")
part("gochujang-meju", "Fermented soybean paste (meju)", "plant", contains=["soy"],
     note="gochujang is fermented with meju, a soybean paste")
part("oyster", "Oyster (molluscan shellfish)", "shellfish",
     note="oysters are molluscs, not crustaceans; US FALCPA requires crustacean labelling only")
part("fish-extract", "Fish extract", "fish", contains=["fish"])
part("shrimp-part", "Salted shrimp (saeujeot)", "shellfish", contains=["crustaceanShellfish"])
part("fish-sauce-part", "Fish sauce", "fish", contains=["fish"])
part("urad-flour", "Urad dal (black gram) flour", "plant")
part("annatto", "Annatto (achiote) seeds", "plant")
part("lime-juice", "Lime juice", "plant", fdc=usda(168156, "Lime Juice (Raw)"))
part("sour-orange-juice", "Sour orange juice", "plant")
part("yogurt-part", "Yogurt", "dairy", contains=["milk"])
simple("ghee", "Ghee", "dairy", contains=["milk"], synonyms=["clarified butter"],
       note="clarified butter: milk fat; lactose reduced but still a milk product")
simple("coconut", "Coconut", "plant",
       allergen_overrides={"treeNuts": f("unknown", "reference", "FDA tree nut list",
          "coconut was historically listed by FDA as a tree nut; 2025 draft guidance proposes removing it; "
          "some tree-nut-allergic individuals react to coconut — treat as unknown")},
       note="botanically a fruit; confirm with the user when their nut allergy excludes coconut")

# ===========================================================================
# Simple identities: the 50 app core ingredients + allergen-bearing corpus names
# ===========================================================================

simple("egg", "Egg", "egg", contains=["egg"], synonyms=["eggs", "eggs (whole)", "boiled eggs", "fried eggs"])
simple("rice", "Rice", "plant", synonyms=["white rice", "uncooked white rice", "cooked rice",
                                          "uncooked basmati rice", "uncooked jasmine rice", "steamed rice"],
       fdc=usda(168877, "White Rice (Raw)"))
simple("chicken-breast", "Chicken breast", "meat", synonyms=["chicken breasts", "chicken"],
       fdc=usda(171052, "Chicken (Meat Only, Raw)"))
simple("onion", "Onion", "plant", synonyms=["onions", "red onion", "shallot", "shallots"],
       fdc=usda(170000, "Onions (Raw)"))
simple("tomato", "Tomato", "plant", synonyms=["tomatoes"], fdc=usda(170457, "Tomatoes (Red, Ripe, Raw)"))
simple("bell-pepper", "Bell pepper", "plant", synonyms=["bell peppers", "red bell peppers",
                                                        "green bell pepper", "peppers"],
       fdc=usda(2258590, "Bell Pepper (Red, Raw)", "closest catalog row (red bell pepper)"))
simple("potato", "Potato", "plant", synonyms=["potatoes", "russet potatoes"],
       fdc=usda(170026, "Potatoes (Raw, Flesh and Skin)"))
simple("carrot", "Carrot", "plant", synonyms=["carrots"], fdc=usda(170393, "Carrots (Raw)"))
simple("mushroom", "Mushroom", "fungus", synonyms=["mushrooms", "white mushrooms", "chestnut mushrooms"],
       fdc=usda(169251, "Mushrooms (White, Raw)"))
simple("spinach", "Spinach", "plant", fdc=usda(168462, "Spinach (Raw)"))
simple("banana", "Banana", "plant", synonyms=["bananas"])
simple("green-onion", "Green onion", "plant", synonyms=["green onions", "scallions", "scallion"],
       fdc=usda(170005, "Green Onions (Scallions, Raw)"))
simple("sesame-oil", "Sesame oil", "plant", contains=["sesame"], synonyms=["toasted sesame oil"],
       fdc=usda(171016, "Sesame Oil"))
simple("broccoli", "Broccoli", "plant", fdc=usda(170379, "Broccoli (Raw)"))
simple("cucumber", "Cucumber", "plant", fdc=usda(168409, "Cucumber (With Peel, Raw)"))
simple("avocado", "Avocado", "plant")
simple("black-beans", "Black beans", "plant", synonyms=["black bean", "cooked black beans"],
       fdc=usda(173735, "Black Beans (Cooked, No Salt)"))
simple("lime", "Lime", "plant", synonyms=["limes"], fdc=usda(168155, "Limes (Raw)"))
simple("ginger", "Ginger", "plant", synonyms=["fresh ginger", "ginger root"],
       fdc=usda(169231, "Ginger Root (Raw)"))
simple("oats", "Oats", "plant", synonyms=["rolled oats", "porridge oats", "oatmeal"], gluten="unknown",
       note="oats are gluten-free by nature but routinely cross-contacted; certification varies",
       forms=[{
           "name": "certified-gluten-free",
           "matchNames": ["certified gluten-free oats", "gluten-free oats", "gluten free oats",
                          "certified gluten free oats", "gf oats"],
           "allergens": {"wheat": f("free", "standard", "oats composition",
                                    "oats are not a wheat species; certified gluten-free oats carry no "
                                    "wheat ingredient (independent of the gluten question)")},
           "gluten": f("free", "label", "certified gluten-free oats label claim",
                       "certified gluten-free: gluten below 20 ppm (21 CFR 101.100)"),
           "diets": {"glutenFree": f("allowed", "label", "certified gluten-free oats label claim",
                                     "certification mark on the product form")},
       }])
simple("yogurt", "Yogurt", "dairy", contains=["milk"], synonyms=["plain yogurt", "natural yogurt"])
simple("honey", "Honey", "insect-product")
simple("corn", "Corn", "plant", synonyms=["sweet corn", "corn kernels"],
       fdc=usda(168538, "Corn (Sweet White, Raw)", "closest catalog row for sweet corn"))
simple("chickpeas", "Chickpeas", "plant", synonyms=["chickpea", "garbanzo beans", "cooked chickpeas"],
       fdc=usda(2644282, "Chickpeas (Dry)"))
simple("salmon", "Salmon", "fish", contains=["fish"], synonyms=["salmon fillets", "salmon fillet"],
       fdc=usda(2684441, "Salmon (Atlantic, Farmed, Raw)"))
simple("sweet-potato", "Sweet potato", "plant", synonyms=["sweet potatoes"])
simple("ground-beef", "Ground beef", "meat", synonyms=["beef mince", "minced beef"],
       fdc=usda(168608, "Ground Beef (Grass-Fed, Raw)", "closest catalog row for ground beef"))
simple("lettuce", "Lettuce", "plant", synonyms=["romaine lettuce", "lettuce leaves"],
       fdc=usda(169247, "Lettuce (Romaine)"))
simple("apple", "Apple", "plant", synonyms=["apples"])
simple("frozen-peas", "Frozen peas", "plant", synonyms=["peas", "green peas", "garden peas"],
       fdc=usda(170419, "Green Peas (Raw)", "closest catalog row for green peas"))
simple("canned-tuna", "Canned tuna", "fish", contains=["fish"],
       synonyms=["canned tuna in water", "tinned tuna", "tuna in water", "canned light tuna"],
       fdc=usda(171986, "Canned Light Tuna (Water-Packed)"))
simple("celery", "Celery", "plant", fdc=usda(169988, "Celery (Raw)"))
simple("zucchini", "Zucchini", "plant", synonyms=["courgette", "courgettes", "zucchinis"],
       fdc=usda(168565, "Zucchini (Baby, Raw)", "closest catalog row"))
simple("red-pepper-flakes", "Red pepper flakes", "plant", synonyms=["chili flakes", "crushed red pepper"],
       fdc=usda(170932, "Red Pepper (Cayenne / Flakes)"))
simple("cumin", "Cumin", "plant", synonyms=["ground cumin", "cumin seed", "cumin seeds"],
       fdc=usda(170923, "Cumin Seed"))
simple("cilantro", "Cilantro", "plant", synonyms=["coriander leaves", "fresh coriander"],
       fdc=usda(169997, "Coriander Leaves (Cilantro)"))
simple("butter", "Butter", "dairy", contains=["milk"],
       note="butter is churned cream; contains no salt in its unsalted form")
simple("milk", "Milk", "dairy", contains=["milk"], synonyms=["whole milk", "cow's milk", "2% milk"],
       fdc=usda(170871, "Milk (2% Reduced Fat)", "closest catalog row for plain milk"))
simple("lemon", "Lemon", "plant", synonyms=["lemons"],
       fdc=usda(167746, "Lemons (Without Peel, Raw)", "closest catalog row (peeled lemon flesh)"))
simple("olive-oil", "Olive oil", "plant", fdc=usda(171413, "Olive Oil"))
# allergen- or diet-bearing simple names from the corpora
simple("edamame", "Edamame", "plant", contains=["soy"], synonyms=["green soybeans"],
       fdc=usda(169282, "Green Soybeans (Raw)", "catalog alt name 'edamame raw'"))
simple("shrimp", "Shrimp", "shellfish", contains=["crustaceanShellfish"],
       synonyms=["prawns", "prawn", "king prawns"])
simple("greek-yogurt", "Greek yogurt", "dairy", contains=["milk"], synonyms=["greek yoghurt", "greek style yogurt"])
simple("peanuts", "Peanuts", "plant", contains=["peanuts"], synonyms=["roasted peanuts", "salted peanuts"])
simple("cashews", "Cashews", "plant", contains=["treeNuts"], synonyms=["cashew nuts", "raw cashews"],
       fdc=usda(170162, "Cashew Nuts (Raw)"))
simple("sesame-seeds", "Sesame seeds", "plant", contains=["sesame"], synonyms=["sesame seed"],
       fdc=usda(170150, "Sesame Seeds (Whole, Dried)"))
simple("mung-bean-sprouts", "Mung bean sprouts", "plant", synonyms=["beansprouts", "bean sprouts"],
       fdc=usda(169957, "Mung Bean Sprouts (Raw)"))
simple("flank-steak", "Flank steak", "meat", synonyms=["beef flank", "flank"])
simple("pork-shoulder", "Pork shoulder", "meat", synonyms=["pork shoulder roast"])
simple("pork-tenderloin", "Pork tenderloin", "meat")
simple("ground-pork", "Ground pork", "meat", synonyms=["pork mince", "minced pork"])
simple("ground-chicken", "Ground chicken", "meat", synonyms=["chicken mince", "minced chicken"])
simple("chicken-thighs", "Chicken thighs", "meat", synonyms=["chicken thigh", "boneless chicken thighs"],
       fdc=usda(171052, "Chicken (Meat Only, Raw)"))
simple("anchovies", "Anchovies", "fish", contains=["fish"], synonyms=["anchovy fillets", "canned anchovies"])
simple("walnuts", "Walnuts", "plant", contains=["treeNuts"], fdc=usda(170187, "English Walnuts"))
simple("almonds", "Almonds", "plant", contains=["treeNuts"], fdc=usda(170568, "Blanched Almonds",
       "closest catalog row"))
simple("peanut-oil", "Peanut oil", "plant", contains=["peanuts"],
       note="unrefined peanut oil contains peanut protein; refined peanut oil is FDA-exempt — "
            "kept 'contains' because unrefined forms exist")
simple("tahini", "Tahini", "plant", contains=["sesame"], synonyms=["tahina", "sesame paste"],
       fdc=usda(170191, "Sesame Butter (Tahini)"))
simple("masa-harina", "Masa harina", "plant", fdc=usda(169696, "Masa Harina (White Corn Flour)"))
simple("semolina", "Semolina", "plant", contains=["wheat"], gluten="contains",
       fdc=usda(168933, "Semolina (Unenriched)"))
simple("all-purpose-flour", "All-purpose flour", "plant", contains=["wheat"], gluten="contains",
       synonyms=["plain flour", "white flour", "flour"], fdc=usda(169761, "All-Purpose Wheat Flour"))
simple("bulgur", "Bulgur", "plant", contains=["wheat"], gluten="contains", synonyms=["bulgur wheat"],
       fdc=usda(170688, "Bulgur (Dry)"))
simple("barley", "Barley", "plant", gluten="contains", synonyms=["pearled barley", "pearl barley"],
       note="barley carries gluten but is not wheat")
simple("couscous", "Couscous", "plant", contains=["wheat"], gluten="contains",
       synonyms=["giant couscous", "pearl couscous", "giant couscous salad"],
       fdc=usda(169700, "Couscous (Cooked)"))
simple("polenta", "Polenta", "plant", synonyms=["cornmeal", "corn meal"])
simple("quinoa", "Quinoa", "plant", fdc=usda(168874, "Quinoa (Uncooked)"))
simple("rice-vinegar", "Rice vinegar", "plant", synonyms=["rice wine vinegar", "seasoned rice vinegar"])
simple("apple-cider-vinegar", "Apple cider vinegar", "plant", synonyms=["cider vinegar"])
simple("red-wine-vinegar", "Red wine vinegar", "plant")
simple("balsamic-vinegar", "Balsamic vinegar", "plant", synonyms=["balsamic"])

# compound-form identities that are simple enough to keep class facts
simple("feta", "Feta", "dairy", contains=["milk"], synonyms=["feta cheese"],
       diet_overrides={"vegetarian": f("violated", "standard", "PDO feta production",
                                       "PDO feta is made with animal rennet")})
simple("ricotta", "Ricotta", "dairy", contains=["milk"], synonyms=["ricotta cheese"],
       diet_overrides={"vegetarian": f("unknown", "standard", "ricotta coagulants vary",
                                       "ricotta is usually acid-coagulated but some brands use rennet")},
       fdc=usda(170851, "Cheese (Ricotta, Whole Milk)"))
simple("monterey-jack", "Monterey Jack", "dairy", contains=["milk"], synonyms=["monterey jack cheese"],
       diet_overrides={"vegetarian": f("unknown", "standard", "cheese coagulants vary",
                                       "coagulant varies by producer")},
       fdc=usda(170844, "Cheese (Monterey)"))
simple("queso-fresco", "Queso fresco", "dairy", contains=["milk"],
       diet_overrides={"vegetarian": f("unknown", "standard", "cheese coagulants vary",
                                       "queso fresco may be acid-set or use rennet, depending on the producer")})

# deliberate exemplar: resolvable identity with NO facts entry (fail-closed test)
simple("artisan-granola-bar", "Artisan granola bar", "plant",
       note="identity without facts: demonstrates fail-closed unknown for a resolvable key")

# ===========================================================================
# Compound identities
# ===========================================================================

compound("soy-sauce", "Soy sauce", [
    comp("soybeans", "certain", ev("standard", "fermented soy-wheat composition",
                                   "soy sauce is brewed from soybeans and wheat")),
    comp("wheat", "certain", ev("standard", "fermented soy-wheat composition",
                                "soy sauce is brewed from soybeans and wheat")),
    comp("salt", "certain", ev("standard", "brine fermentation")),
    comp("water", "certain", ev("standard", "brine fermentation")),
], composition_complete=True,
    synonyms=["shoyu", "soy_sauce", "light soy sauce", "dark soy sauce"],
    fdc=usda(174278, "Soy Sauce (Tamari)", "catalog alt name 'soy sauce'"),
    note="generic brewed soy sauce carries soy and wheat")

compound("pasta", "Pasta", [
    comp("durum-wheat-flour", "certain", ev("standard", "dried pasta composition",
                                            "dried pasta is milled durum wheat and water")),
    comp("water", "certain", ev("standard", "dried pasta composition")),
], composition_complete=True,
    synonyms=["spaghetti", "penne", "fusilli", "macaroni", "dried pasta"],
    note="dried pasta; fresh egg pasta is a distinct form (dried egg noodles are a separate entry)")

compound("cheese", "Cheese", [
    comp("milk", "certain", ev("standard", "cheese composition", "cheese is coagulated milk")),
    comp("lactic-cultures", "certain", ev("standard", "cheese composition")),
    comp("animal-rennet", "variable", ev("standard", "cheese coagulants vary",
         "coagulant varies: microbial rennet, animal rennet or acid, depending on the cheese")),
], composition_complete=False,
    synonyms=["shredded cheese", "grated cheese"],
    note="generic cheese; coagulant varies, so vegetarian status is unknown (parmesan is a separate entry)")

compound("bread", "Bread", [
    comp("wheat-flour", "certain", ev("standard", "bread composition",
                                      "bread dough is wheat flour, water, yeast and salt")),
    comp("water", "certain", ev("standard", "bread composition")),
    comp("yeast", "certain", ev("standard", "bread composition")),
    comp("salt", "certain", ev("standard", "bread composition")),
    comp("milk-powder", "typical", ev("standard", "enriched sandwich bread",
         "supermarket sandwich breads are usually enriched with milk powder and sugar; "
         "lean doughs (baguette) omit them")),
    comp("sugar", "typical", ev("standard", "enriched sandwich bread")),
    comp("soybean-oil-refined", "typical", ev("standard", "enriched sandwich bread",
         "sandwich breads typically contain vegetable fat; refined soybean oil is FDA-exempt from soy labeling")),
    comp("milk-derivatives", "variable", ev("standard", "bread enrichment varies",
         "some breads use whey or milk powder, others none — milk is typical but not certain")),
    comp("egg", "variable", ev("standard", "enriched bread variants",
         "brioche and challah contain egg; standard sandwich bread does not")),
], composition_complete=False,
    synonyms=["sandwich bread", "sliced bread", "white bread", "sourdough"],
    note="generic bread; enriched sandwich bread is the typical form")

compound("gluten-free-bread", "Gluten-free bread", [
    comp("wheat-starch", "typical", ev("label", "gluten-free bread ingredient declarations",
         "commercial gluten-free breads commonly declare wheat starch, a wheat-derived ingredient "
         "processed to remove gluten")),
    comp("rice-flour", "typical", ev("standard", "gluten-free bread composition",
         "gluten-free breads are built on starches and flours such as rice, tapioca and potato")),
    comp("egg", "variable", ev("standard", "gluten-free bread variants",
         "many gluten-free breads bind with egg or psyllium; presence varies")),
], composition_complete=False,
    allergen_overrides={"wheat": f("contains", "label", "declared wheat starch in gluten-free bread",
                                   "a declared wheat-derived component is a wheat ingredient; the "
                                   "gluten-free label does not change wheat status (FDA gluten-free "
                                   "labeling Q&A, General question 6)")},
    gluten_override=f("free", "label", "gluten-free bread label claim",
                      "labeled gluten-free: gluten below 20 ppm (21 CFR 101.100)"),
    diet_overrides={"glutenFree": f("allowed", "label", "gluten-free bread label claim",
                                    "gluten-free label claim on the product")},
    synonyms=["gf bread", "gluten free bread"],
    note="the FDA case: gluten-free label AND declared wheat-derived component — gluten-free "
         "diet allowed, wheat allergen still violated")

compound("tofu", "Tofu", [
    comp("soybeans", "certain", ev("standard", "tofu composition", "tofu is coagulated soy milk")),
    comp("water", "certain", ev("standard", "tofu composition")),
    comp("lactic-cultures", "typical", ev("standard", "tofu coagulants",
         "coagulated with nigari (magnesium chloride) or calcium sulfate")),
], composition_complete=True,
    synonyms=["firm tofu", "silken tofu", "bean curd"])

compound("tortilla", "Tortilla", [],
    composition_complete=False,
    synonyms=["tortillas", "tortilla wraps"],
    allergen_overrides={"wheat": f("unknown", "standard", "tortilla styles vary",
                                   "'tortilla' alone is ambiguous: corn tortillas contain no wheat, flour tortillas do")},
    gluten="unknown", gluten_note="corn tortillas are gluten-free; flour tortillas contain wheat gluten",
    diet_overrides={"vegetarian": f("unknown", "standard", "flour tortilla fat varies",
                                    "flour tortillas may be made with lard; corn tortillas with oil — varies by product")},
    note="generic tortilla; corn and flour forms are separate entries")

compound("peanut-butter", "Peanut butter", [
    comp("peanuts-part", "certain", ev("standard", "peanut butter composition",
                                       "peanut butter is ground peanuts")),
    comp("sugar", "typical", ev("standard", "commercial peanut butter",
                                "many brands add sugar and palm oil as stabilisers")),
    comp("palm-oil", "typical", ev("standard", "commercial peanut butter")),
    comp("salt", "typical", ev("standard", "commercial peanut butter")),
], composition_complete=True,
    fdc=usda(169869, "Peanut Butter (Reduced Sodium)"),
    note="peanuts are legumes, not tree nuts; typical brands contain no other major allergen")

compound("coconut-milk", "Coconut milk", [
    comp("coconut", "certain", ev("standard", "coconut milk composition",
                                  "coconut milk is grated coconut flesh and water")),
    comp("water", "certain", ev("standard", "coconut milk composition")),
], composition_complete=True, fdc=usda(170172, "Coconut Milk (Raw)"))

compound("worcestershire-sauce", "Worcestershire sauce", [
    comp("anchovy", "certain", ev("standard", "Worcestershire sauce composition",
                                  "Worcestershire sauce is fermented with anchovies (Lea & Perrins style)")),
    comp("distilled-vinegar", "typical", ev("standard", "Worcestershire sauce composition",
         "US recipes use distilled white vinegar; UK recipes malt vinegar")),
    comp("malt-vinegar", "variable", ev("standard", "Worcestershire sauce composition varies",
         "UK-made Worcestershire sauce uses malt vinegar (barley); US-market bottles distilled vinegar")),
    comp("molasses", "typical", ev("standard", "Worcestershire sauce composition")),
    comp("sugar", "typical", ev("standard", "Worcestershire sauce composition")),
    comp("spices", "typical", ev("standard", "Worcestershire sauce composition")),
], composition_complete=False, synonyms=["worcestershire"])

compound("fish-sauce", "Fish sauce", [
    comp("anchovy", "certain", ev("standard", "fish sauce composition",
                                  "fish sauce is fermented anchovies and salt")),
    comp("salt", "certain", ev("standard", "fish sauce composition")),
    comp("water", "certain", ev("standard", "fish sauce composition")),
], composition_complete=True,
    synonyms=["nam pla", "nuoc mam", "thai fish sauce", "vietnamese fish sauce"])

compound("tamari", "Tamari", [
    comp("soybeans", "certain", ev("standard", "tamari composition",
                                   "tamari is a soybean-dominant fermented sauce")),
    comp("wheat", "unknown", ev("standard", "tamari wheat status varies",
         "classic tamari is wheat-free or near-wheat-free, but commercial products vary; "
         "only a product ingredient declaration settles wheat")),
], composition_complete=False,
    synonyms=["tamari soy sauce", "japanese tamari"],
    fdc=usda(174278, "Soy Sauce (Tamari)", "catalog display name 'Soy Sauce (Tamari)'"),
    note="tamari vs wheat: unknown unless a product ingredient declaration settles it; "
         "a gluten-free label never establishes wheat absence (FDA permits processed "
         "wheat-derived ingredients in gluten-free foods)",
    forms=[{
        "name": "certified-gluten-free",
        "matchNames": ["certified gluten-free tamari", "gluten-free tamari", "gluten free tamari",
                       "certified gluten free tamari", "tamari (certified gluten-free)"],
        "allergens": {"wheat": f("unknown", "standard", "FDA gluten-free labeling rule (21 CFR 101.100)",
                                 "the gluten-free label does not establish wheat absence: FDA permits "
                                 "processed wheat-derived ingredients in gluten-free foods; tamari's "
                                 "wheat status needs a product ingredient declaration")},
        "gluten": f("free", "label", "certified gluten-free tamari label claim",
                    "certified gluten-free: gluten below 20 ppm (21 CFR 101.100)"),
        "diets": {"glutenFree": f("allowed", "label", "certified gluten-free tamari label claim",
                                  "certification mark on the product form defined in identities.json")},
    }])

compound("miso", "Miso", [
    comp("soybeans", "certain", ev("standard", "miso composition", "miso is fermented soybean paste")),
    comp("rice-koji", "variable", ev("standard", "miso koji varies",
         "koji is usually grown on rice, but barley koji (mugi miso) is a standard variant "
         "that introduces gluten")),
    comp("salt", "certain", ev("standard", "miso composition")),
], composition_complete=False,
    synonyms=["miso paste", "soybean paste", "white miso", "red miso"])

compound("pesto", "Pesto", [
    comp("basil", "certain", ev("standard", "pesto alla genovese")),
    comp("pine-nuts", "certain", ev("standard", "pesto alla genovese",
         "traditional pesto uses pine nuts; commercial jars often substitute cashews or walnuts — "
         "always tree nuts")),
    comp("parmesan", "certain", ev("standard", "pesto alla genovese",
         "pesto carries parmesan (or pecorino): milk, and animal rennet")),
    comp("olive-oil", "certain", ev("standard", "pesto alla genovese")),
    comp("garlic", "certain", ev("standard", "pesto alla genovese")),
    comp("salt", "certain", ev("standard", "pesto alla genovese")),
], composition_complete=True,
    synonyms=["pesto sauce", "pesto alla genovese", "basil pesto"])

compound("lard", "Lard", [
    comp("pork-fat", "certain", ev("standard", "lard composition", "lard is rendered pork fat")),
], composition_complete=True)

compound("gelatin", "Gelatin", [
    comp("animal-collagen", "certain", ev("standard", "gelatin composition",
           "gelatin is collagen extracted from animal skin and bones (pork or beef)")),
], composition_complete=True, synonyms=["gelatine", "unflavored gelatin", "granulated gelatin"])

compound("parmesan", "Parmesan", [
    comp("milk", "certain", ev("standard", "parmesan composition", "parmesan is cow's milk cheese")),
    comp("animal-rennet", "certain", ev("standard", "Parmigiano-Reggiano production discipline",
         "Parmigiano-Reggiano PDO requires calf rennet; grana padano likewise uses animal rennet")),
    comp("salt", "certain", ev("standard", "parmesan composition")),
], composition_complete=True,
    synonyms=["parmesan cheese", "parmigiano reggiano", "parmigiano-reggiano", "grana padano"],
    fdc=usda(170848, "Cheese (Parmesan, Hard)"))

compound("cream-cheese", "Cream cheese", [
    comp("milk", "certain", ev("standard", "cream cheese composition",
                               "cream cheese is milk and cream, acid-set")),
    comp("cream", "certain", ev("standard", "cream cheese composition")),
    comp("lactic-cultures", "certain", ev("standard", "cream cheese composition",
          "acid-set with lactic cultures; no rennet")),
], composition_complete=True,
    synonyms=["philadelphia cheese", "soft cheese"],
    fdc=usda(169079, "Cheese (Cream, Low Fat)", "closest catalog row (low-fat cream cheese)"))

compound("flour-tortillas", "Flour tortillas", [
    comp("wheat-flour", "certain", ev("standard", "flour tortilla composition")),
    comp("water", "certain", ev("standard", "flour tortilla composition")),
    comp("salt", "certain", ev("standard", "flour tortilla composition")),
    comp("pork-fat", "variable", ev("standard", "flour tortilla fat varies",
         "traditional flour tortillas use lard; commercial packs use vegetable oil — varies by product")),
    comp("milk-powder", "variable", ev("standard", "flour tortilla fat varies",
          "some commercial packs add milk powder")),
], composition_complete=False, synonyms=["flour tortilla", "wheat tortillas"])

compound("corn-tortillas", "Corn tortillas", [
    comp("masa-harina", "certain", ev("standard", "corn tortilla composition",
                                      "corn tortillas are masa harina, water and salt")),
    comp("water", "certain", ev("standard", "corn tortilla composition")),
    comp("salt", "certain", ev("standard", "corn tortilla composition")),
], composition_complete=True, synonyms=["corn tortilla"])

compound("kimchi", "Kimchi", [
    comp("napa-cabbage", "certain", ev("standard", "kimchi composition")),
    comp("gochugaru", "certain", ev("standard", "kimchi composition")),
    comp("garlic", "certain", ev("standard", "kimchi composition")),
    comp("fish-sauce-part", "variable", ev("standard", "kimchi composition varies",
          "many kimchi recipes include fish sauce or saeujeot (salted shrimp); vegan variants omit them")),
    comp("shrimp-part", "variable", ev("standard", "kimchi composition varies",
          "saeujeot (salted shrimp) is common but not universal")),
], composition_complete=False,
    synonyms=["baechu kimchi", "chinese cabbage kimchi"],
    fdc=usda(170392, "Cabbage (Kimchi)"))

compound("gochujang", "Gochujang", [
    comp("chili-peppers", "certain", ev("standard", "gochujang composition")),
    comp("gochujang-meju", "certain", ev("standard", "gochujang composition",
          "gochujang is fermented with meju (soybean) paste")),
    comp("glutinous-rice", "typical", ev("standard", "gochujang composition",
          "glutinous rice powder is the usual starch")),
    comp("barley-malt", "variable", ev("standard", "gochujang composition varies",
          "some gochujang is sweetened with barley malt syrup")),
    comp("salt", "certain", ev("standard", "gochujang composition")),
], composition_complete=False, synonyms=["korean chili paste", "hot pepper paste"])

compound("oyster-sauce", "Oyster sauce", [
    comp("oyster", "certain", ev("standard", "oyster sauce composition",
          "oyster sauce is oyster extract condiment")),
    comp("sugar", "certain", ev("standard", "oyster sauce composition")),
    comp("salt", "certain", ev("standard", "oyster sauce composition")),
    comp("corn-starch-modified", "typical", ev("standard", "oyster sauce composition")),
    comp("caramel-colour", "typical", ev("standard", "oyster sauce composition")),
    comp("monosodium-glutamate", "typical", ev("standard", "oyster sauce composition")),
    comp("wheat", "variable", ev("standard", "oyster sauce composition varies",
          "some oyster sauce brands include wheat flour as a thickener")),
], composition_complete=False, synonyms=["oyster flavoured sauce"],
    allergen_overrides={"crustaceanShellfish": f("unknown", "reference", "US FALCPA crustacean scope",
        "oysters are molluscan shellfish, not crustaceans; FALCPA requires crustacean labelling only, "
        "but some crustacean-allergic people react to molluscs")})

compound("sriracha", "Sriracha", [
    comp("chili-peppers", "certain", ev("standard", "sriracha composition")),
    comp("sugar", "certain", ev("standard", "sriracha composition")),
    comp("garlic", "certain", ev("standard", "sriracha composition")),
    comp("distilled-vinegar", "certain", ev("standard", "sriracha composition")),
    comp("salt", "certain", ev("standard", "sriracha composition")),
], composition_complete=True)

compound("harissa", "Harissa", [
    comp("chili-peppers", "certain", ev("standard", "harissa composition")),
    comp("garlic", "typical", ev("standard", "harissa composition")),
    comp("spices", "typical", ev("standard", "harissa composition",
          "coriander, cumin and caraway are standard spices")),
    comp("olive-oil", "typical", ev("standard", "harissa composition")),
    comp("salt", "certain", ev("standard", "harissa composition")),
], composition_complete=True, synonyms=["harissa paste", "rose harissa"])

compound("mayonnaise", "Mayonnaise", [
    comp("egg", "certain", ev("standard", "mayonnaise composition",
          "mayonnaise is an egg-and-oil emulsion (egg-free products are distinct items, "
          "e.g. tofu mayonnaise in the catalog)")),
    comp("soybean-oil-refined", "typical", ev("standard", "mayonnaise composition",
          "most commercial mayonnaise uses refined soybean oil (FDA-exempt from soy labeling)")),
    comp("distilled-vinegar", "typical", ev("standard", "mayonnaise composition")),
    comp("lemon-juice", "variable", ev("standard", "mayonnaise acid varies",
          "acid is vinegar or lemon juice, by recipe")),
    comp("mustard", "variable", ev("standard", "mayonnaise seasonings vary",
          "some recipes include mustard")),
    comp("salt", "certain", ev("standard", "mayonnaise composition")),
], composition_complete=False, synonyms=["mayo", "real mayonnaise"],
    fdc=usda(171009, "Mayonnaise Dressing", "catalog alt name 'mayonnaise'"))

compound("spicy-mayo", "Spicy mayo", [
    comp("mayonnaise", "certain", ev("recipe", "bundled recipe step 'spicy mayo'",
          "spicy mayo is mayonnaise plus hot sauce in the bundled recipes")),
    comp("sriracha", "typical", ev("recipe", "bundled recipe step 'spicy mayo'")),
], composition_complete=False)

compound("hummus", "Hummus", [
    comp("chickpeas", "certain", ev("standard", "hummus composition")),
    comp("tahini", "certain", ev("standard", "hummus composition",
          "hummus bi tahina carries sesame paste")),
    comp("lemon-juice", "certain", ev("standard", "hummus composition")),
    comp("garlic", "certain", ev("standard", "hummus composition")),
    comp("olive-oil", "typical", ev("standard", "hummus composition")),
    comp("salt", "certain", ev("standard", "hummus composition")),
], composition_complete=True)

compound("raita", "Raita", [
    comp("yogurt-part", "certain", ev("standard", "raita composition")),
    comp("cucumber", "typical", ev("standard", "raita composition")),
    comp("mint", "typical", ev("standard", "raita composition")),
    comp("spices", "typical", ev("standard", "raita composition")),
], composition_complete=True)

compound("gremolata", "Gremolata", [
    comp("parsley", "certain", ev("standard", "gremolata composition")),
    comp("lemon-zest", "certain", ev("standard", "gremolata composition")),
    comp("garlic", "certain", ev("standard", "gremolata composition")),
], composition_complete=True)

compound("breadcrumbs", "Breadcrumbs", [
    comp("bread", "certain", ev("standard", "breadcrumb composition",
          "breadcrumbs are dried or grated bread")),
], composition_complete=False, synonyms=["bread crumbs", "panko"])

compound("naan", "Naan", [
    comp("wheat-flour", "certain", ev("standard", "naan composition")),
    comp("yogurt-part", "typical", ev("standard", "naan composition",
          "naan dough usually contains yogurt or milk")),
    comp("milk-powder", "typical", ev("standard", "naan composition")),
    comp("egg", "variable", ev("standard", "naan composition varies",
          "some naan recipes include egg")),
    comp("ghee", "typical", ev("standard", "naan composition")),
    comp("yeast", "typical", ev("standard", "naan composition")),
    comp("salt", "certain", ev("standard", "naan composition")),
], composition_complete=False, synonyms=["naan bread", "naan breads", "garlic naan"])

compound("flatbread", "Flatbread", [],
    composition_complete=False, synonyms=["flatbreads", "flat bread"],
    allergen_overrides={"wheat": f("unknown", "standard", "flatbread styles vary",
                                   "flatbreads range from wheat (chapati) to corn (arepas) — variety is not determined by the name")},
    gluten="unknown", gluten_note="flatbread variety varies: wheat flatbreads contain gluten, corn ones do not",
    diet_overrides={"vegetarian": f("unknown", "standard", "flatbread fat varies",
                                    "some flatbreads are brushed with ghee or butter; variety is not determined by the name")})

compound("pitta", "Pitta", [
    comp("wheat-flour", "certain", ev("standard", "pitta composition")),
    comp("yeast", "certain", ev("standard", "pitta composition")),
    comp("olive-oil", "typical", ev("standard", "pitta composition")),
    comp("salt", "certain", ev("standard", "pitta composition")),
    comp("water", "certain", ev("standard", "pitta composition")),
    comp("milk-powder", "variable", ev("standard", "commercial pitta varies",
          "some packs add milk powder")),
], composition_complete=False, synonyms=["pita", "pita bread", "pitta bread"])

compound("taco-shells", "Taco shells", [
    comp("masa-harina", "certain", ev("standard", "taco shell composition",
                                      "hard taco shells are fried corn tortillas")),
    comp("vegetable-oil-blend", "typical", ev("standard", "taco shell composition",
          "fried in vegetable oil")),
    comp("salt", "certain", ev("standard", "taco shell composition")),
], composition_complete=True, synonyms=["corn taco shells", "hard taco shells"])

compound("dried-egg-noodles", "Dried egg noodles", [
    comp("wheat-flour", "certain", ev("standard", "egg noodle composition")),
    comp("egg", "certain", ev("standard", "egg noodle composition",
          "egg noodles are wheat dough with egg")),
    comp("water", "certain", ev("standard", "egg noodle composition")),
], composition_complete=True, synonyms=["egg noodles", "dried noodles"],
    fdc=usda(169731, "Egg Noodles (Dry, Enriched)"))

compound("rice-noodles", "Rice noodles", [
    comp("rice", "certain", ev("standard", "rice noodle composition")),
    comp("water", "certain", ev("standard", "rice noodle composition")),
], composition_complete=True, synonyms=["cooked rice noodles", "dried rice noodles", "rice noodle", "flat rice noodles"],
    fdc=usda(169742, "Rice Noodles (Dry)"))

compound("achiote-paste", "Achiote paste", [
    comp("annatto", "certain", ev("standard", "recado rojo composition")),
    comp("garlic", "typical", ev("standard", "recado rojo composition")),
    comp("spices", "typical", ev("standard", "recado rojo composition")),
    comp("sour-orange-juice", "typical", ev("standard", "recado rojo composition")),
    comp("salt", "certain", ev("standard", "recado rojo composition")),
], composition_complete=True, synonyms=["achiote", "recado rojo"])

compound("chaat-masala", "Chaat masala", [
    comp("spices", "certain", ev("standard", "chaat masala composition",
          "amchoor, cumin, coriander, dried ginger, salt, pepper and ajwain are standard")),
    comp("anti-caking-agent", "variable", ev("standard", "jarred spice blends vary",
          "jarred blends may add anti-caking agents")),
], composition_complete=False, synonyms=["chaat masala spice mix"])

compound("garam-masala", "Garam masala", [
    comp("spices", "certain", ev("standard", "garam masala composition",
          "cardamom, cinnamon, cloves, cumin and coriander are standard")),
    comp("anti-caking-agent", "variable", ev("standard", "jarred spice blends vary",
          "jarred blends may add anti-caking agents")),
], composition_complete=False)

compound("curry-powder", "Curry powder", [
    comp("spices", "certain", ev("standard", "curry powder composition",
          "turmeric, coriander, cumin, fenugreek and chili are standard")),
    comp("anti-caking-agent", "variable", ev("standard", "jarred spice blends vary",
          "jarred blends may add anti-caking agents")),
], composition_complete=False, fdc=usda(170924, "Curry Powder"))

compound("chipotle-in-adobo", "Chipotle in adobo", [
    comp("chili-peppers", "certain", ev("standard", "canned chipotle in adobo",
          "smoked jalapeños in adobo sauce")),
    comp("tomato", "certain", ev("standard", "canned chipotle in adobo")),
    comp("distilled-vinegar", "certain", ev("standard", "canned chipotle in adobo")),
    comp("onion", "typical", ev("standard", "canned chipotle in adobo")),
    comp("sugar", "typical", ev("standard", "canned chipotle in adobo")),
    comp("salt", "certain", ev("standard", "canned chipotle in adobo")),
    comp("spices", "typical", ev("standard", "canned chipotle in adobo")),
], composition_complete=True,
    synonyms=["chipotle peppers in adobo", "chipotles in adobo", "chipotle in adobo sauce"])

compound("tomato-paste", "Tomato paste", [
    comp("tomato", "certain", ev("standard", "tomato paste composition",
          "tomato paste is concentrated tomatoes, sometimes with salt")),
    comp("salt", "variable", ev("standard", "tomato paste composition varies",
          "some brands add salt")),
], composition_complete=True, synonyms=["tomato puree", "tomato purée", "tomato concentrate"])

compound("tomato-sauce", "Tomato sauce", [
    comp("tomato", "certain", ev("standard", "tomato sauce composition")),
    comp("salt", "typical", ev("standard", "tomato sauce composition")),
], composition_complete=True, synonyms=["passata", "canned tomato sauce"],
    fdc=usda(170054, "Tomato Sauce (Canned)"))

compound("mirin", "Mirin", [
    comp("glutinous-rice", "certain", ev("standard", "hon mirin composition")),
    comp("rice-koji", "certain", ev("standard", "hon mirin composition")),
    comp("distilled-spirit", "typical", ev("standard", "hon mirin composition",
          "brewed with shochu; distillation removes gluten protein even from barley-derived spirit")),
    comp("sugar", "typical", ev("standard", "aji-mirin style", "seasoned aji-mirin adds sugar and salt")),
    comp("salt", "typical", ev("standard", "aji-mirin style")),
], composition_complete=True, synonyms=["sweet mirin", "hon mirin", "aji-mirin"],
    note="hon mirin is rice, koji and distilled spirit — gluten-free by composition")

compound("chicken-stock", "Chicken stock", [
    comp("chicken", "certain", ev("standard", "stock composition",
                                  "chicken stock is simmered chicken bones and meat")),
    comp("vegetables-mixed", "typical", ev("standard", "stock composition",
           "aromatic vegetables are standard")),
    comp("salt", "typical", ev("standard", "stock composition")),
    comp("stock-additives", "variable", ev("standard", "commercial stock varies",
           "commercial stocks and bouillon powders vary: milk derivatives, soy or celery appear in some brands")),
], composition_complete=False, synonyms=["chicken broth", "chicken bone broth"])

compound("vegetable-stock", "Vegetable stock", [
    comp("vegetables-mixed", "certain", ev("standard", "stock composition",
           "vegetable stock is simmered vegetables")),
    comp("salt", "typical", ev("standard", "stock composition")),
    comp("stock-additives", "variable", ev("standard", "commercial stock varies",
           "commercial vegetable stocks vary: milk derivatives, soy or celery appear in some brands")),
], composition_complete=False, synonyms=["veg stock", "vegetable broth"],
    note="homemade vegetable stock is vegan; commercial cubes vary, so diet facts stay unknown")

compound("stock-cube", "Stock cube (bouillon)", [
    comp("salt", "certain", ev("standard", "stock cube composition",
                               "salt is the defining base of bouillon cubes")),
    comp("flavourings-unknown", "variable", ev("standard", "stock cube composition varies by brand",
          "flavourings, flavour enhancers and spice extracts vary by brand")),
    comp("hydrolysed-plant-protein", "variable", ev("standard", "stock cube composition varies by brand",
          "HVP may derive from soy, wheat, maize or rice")),
    comp("milk-derivatives", "variable", ev("standard", "stock cube composition varies by brand",
          "whey or lactose appear in some brands")),
    comp("fat-source-varies", "variable", ev("standard", "stock cube composition varies by brand",
          "the fat may be vegetable or animal (some brands use lard)")),
], composition_complete=False,
    synonyms=["bouillon", "bouillon cube", "bouillon powder", "stock pot", "stock cubes"])

# extra parts introduced above
part("peanuts-part", "Peanuts", "plant", contains=["peanuts"])
simple("sour-cream", "Sour cream", "dairy", contains=["milk"],
       synonyms=["crema", "mexican crema"],
       fdc=usda(173443, "Sour Cream (Light)", "closest catalog row (light sour cream)"))
simple("halloumi", "Halloumi", "dairy", contains=["milk"],
       diet_overrides={"vegetarian": f("unknown", "standard", "halloumi coagulants vary",
                                       "traditional halloumi uses animal rennet; some brands use microbial rennet")})
simple("paneer", "Paneer", "dairy", contains=["milk"],
       note="acid-set with lemon juice or vinegar; standard paneer contains no rennet")
simple("beef", "Beef", "meat")
simple("tuna", "Tuna", "fish", contains=["fish"], synonyms=["tuna steak"],
       note="generic tuna covers fresh steaks and canned; canned tuna is a separate entry")

compound("chilli-sauce", "Chilli sauce", [
    comp("chili-peppers", "certain", ev("standard", "chilli sauce composition")),
    comp("sugar", "certain", ev("standard", "chilli sauce composition")),
    comp("food-acid", "typical", ev("standard", "chilli sauce composition")),
    comp("garlic", "typical", ev("standard", "chilli sauce composition")),
], composition_complete=False,
    synonyms=["chili sauce", "sweet chili sauce", "sweet chilli sauce"],
    note="generic chilli sauce: thickeners and preservatives vary by brand")

compound("chorizo", "Chorizo", [
    comp("pork", "certain", ev("standard", "chorizo composition",
                               "chorizo is a pork sausage (Spanish cured or Mexican fresh)")),
    comp("spices", "certain", ev("standard", "chorizo composition",
                                 "smoked paprika (pimenton) is the defining spice")),
    comp("garlic", "typical", ev("standard", "chorizo composition")),
], composition_complete=False,
    diet_overrides={
        "vegetarian": f("violated", "standard", "chorizo composition", "pork is a certain component"),
        "vegan": f("violated", "standard", "chorizo composition", "pork is a certain component"),
        "pescatarian": f("violated", "standard", "chorizo composition", "pork is a certain component"),
    },
    note="casing and fillers vary; some fresh chorizo contains wheat-based rusk or starch")

# ---- corpus compound expansion (from the originals compound-allergens tables) ----

part("cocoa", "Cocoa powder", "plant", fdc=usda(170150, "Cocoa (Unsweetened)"))
part("vinegar", "Vinegar", "plant", gluten="unknown",
     note="generic vinegar: distilled/spirit vinegar is gluten-free, malt vinegar is not; "
          "variety varies by product")

compound("chocolate", "Chocolate", [
    comp("cocoa", "certain", ev("standard", "chocolate composition",
         "chocolate is cocoa solids and cocoa butter")),
    comp("sugar", "certain", ev("standard", "chocolate composition")),
    comp("milk", "variable", ev("standard", "chocolate composition varies",
         "dark chocolate usually contains no milk (but check the label for milk fat); "
         "milk chocolate always does")),
], composition_complete=False,
    note="generic chocolate: milk presence varies by type; nut inclusions vary")

simple("pecan", "Pecan", "plant", contains=["treeNuts"], synonyms=["pecans", "pecan nuts"],
       fdc=usda(170182, "Pecans (Raw)"))
simple("pistachio", "Pistachio", "plant", contains=["treeNuts"], synonyms=["pistachios"],
       fdc=usda(170183, "Pistachios (Roasted)"))
simple("hazelnut", "Hazelnut", "plant", contains=["treeNuts"], synonyms=["hazelnuts", "filberts", "cobnuts"],
       fdc=usda(170589, "Hazelnuts (Raw)"))
simple("macadamia", "Macadamia", "plant", contains=["treeNuts"], synonyms=["macadamias", "macadamia nuts"],
       fdc=usda(170586, "Macadamia Nuts (Raw)"))
simple("crab", "Crab", "shellfish", contains=["crustaceanShellfish"], synonyms=["crab meat"],
       fdc=usda(2684537, "Crab (Blue, Canned)", "closest catalog row for crab meat"))
simple("lobster", "Lobster", "shellfish", contains=["crustaceanShellfish"])
simple("scallop", "Scallop", "shellfish", synonyms=["scallops", "scallop meat"],
       note="molluscan bivalve: FALCPA does not list molluscs among the nine major allergens, "
            "but shellfish allergy covers them; declared unknown pending user confirmation")
simple("mussel", "Mussel", "shellfish", synonyms=["mussels"],
       note="molluscan bivalve: not one of the nine FDA major allergens; shellfish allergy covers it")
simple("clam", "Clam", "shellfish", synonyms=["clams"],
       note="molluscan bivalve: not one of the nine FDA major allergens; shellfish allergy covers it")
simple("cod", "Cod", "fish", contains=["fish"])
simple("trout", "Trout", "fish", contains=["fish"])
simple("halibut", "Halibut", "fish", contains=["fish"])
simple("mackerel", "Mackerel", "fish", contains=["fish"])
simple("sardine", "Sardine", "fish", contains=["fish"], synonyms=["sardines"])
simple("whitefish", "Whitefish", "fish", contains=["fish"], synonyms=["white fish"],
       note="generic white-fleshed fish; species varies")
simple("smoked-salmon", "Smoked salmon", "fish", contains=["fish"], synonyms=["gravlax"],
       note="curing/serving temperature is a food-safety question, not an allergen one")
simple("fish-fillet", "Fish fillet", "fish", contains=["fish"],
       synonyms=["fish fillets", "white fish fillet", "white fish fillets"],
       note="generic fillet: species varies")
simple("fish-stock", "Fish stock", "fish", contains=["fish"], synonyms=["fish broth", "fumet"],
       note="fish stock is fish-based by definition")
simple("beef-stock", "Beef stock", "meat", synonyms=["beef broth"],
       note="beef stock is beef-based by definition")
simple("shrimp-stock", "Shrimp stock", "shellfish", contains=["crustaceanShellfish"],
       synonyms=["shrimp broth"],
       note="shrimp stock is shellfish-based by definition")
simple("turkey", "Turkey", "meat", synonyms=["turkey breast"])
simple("ground-turkey", "Ground turkey", "meat", synonyms=["turkey mince", "minced turkey"])
simple("duck", "Duck", "meat", synonyms=["duck breast"])
simple("lamb", "Lamb", "meat", synonyms=["lamb shoulder", "lamb leg"])
simple("ground-lamb", "Ground lamb", "meat", synonyms=["lamb mince", "minced lamb"])
simple("steak", "Steak", "meat", synonyms=["beef steak", "rump steak", "sirloin"])
simple("pork-chop", "Pork chop", "meat", synonyms=["pork chops"])
simple("sausage", "Sausage", "meat", note="generic sausage: meat species and fillers vary by product")
simple("chicken-liver", "Chicken liver", "meat", synonyms=["livers"],
       note="offal: animal flesh for diet purposes")
simple("bacon", "Bacon", "meat", synonyms=["streaky bacon", "bacon rashers"])
simple("duck-fat", "Duck fat", "animal-derived", synonyms=["rendered duck fat"])
simple("cotija", "Cotija", "dairy", contains=["milk"], synonyms=["cotija cheese"])
simple("condensed-milk", "Condensed milk", "dairy", contains=["milk"],
       synonyms=["sweetened condensed milk"],
       fdc=usda(167945, "Sweetened Condensed Milk (Canned)"))
simple("whey", "Whey", "dairy", contains=["milk"], note="milk-derived protein")

compound("teriyaki", "Teriyaki", [
    comp("soy-sauce", "certain", ev("standard", "teriyaki composition",
         "teriyaki sauce is soy-sugar-mirin based")),
    comp("sugar", "certain", ev("standard", "teriyaki composition")),
    comp("mirin", "typical", ev("standard", "teriyaki composition")),
], composition_complete=False,
    note="thickeners (corn starch) vary; some bottled teriyaki contains sesame oil")

compound("hoisin", "Hoisin sauce", [
    comp("soybeans", "certain", ev("standard", "hoisin composition",
         "hoisin is fermented soybean paste based")),
    comp("sugar", "certain", ev("standard", "hoisin composition")),
    comp("vinegar", "typical", ev("standard", "hoisin composition")),
    comp("garlic", "typical", ev("standard", "hoisin composition")),
    comp("spices", "typical", ev("standard", "hoisin composition")),
    comp("wheat-flour", "variable", ev("standard", "hoisin thickener varies",
         "some recipes and brands use wheat flour or wheat-containing colourings")),
    comp("sesame-oil", "variable", ev("standard", "hoisin composition varies",
         "some brands include sesame oil or sesame paste")),
], composition_complete=False,
    note="fermented soybean sauce: sweet bean sauce variants differ by region")

compound("doenjang", "Doenjang", [
    comp("soybeans", "certain", ev("standard", "doenjang composition",
         "doenjang is Korean fermented soybean paste")),
    comp("salt", "certain", ev("standard", "doenjang composition")),
    comp("rice-koji", "typical", ev("standard", "doenjang fermentation",
         "traditionally fermented with meju (soybean brick); rice or barley koji is common")),
], composition_complete=True,
    note="barley-koji variants introduce gluten; meju-only fermentation does not")

compound("ssamjang", "Ssamjang", [
    comp("doenjang", "typical", ev("standard", "ssamjang composition",
         "ssamjang blends doenjang and gochujang")),
    comp("gochujang", "typical", ev("standard", "ssamjang composition")),
    comp("garlic", "typical", ev("standard", "ssamjang composition")),
    comp("sesame-oil", "typical", ev("standard", "ssamjang composition")),
], composition_complete=False,
    note="brand blends vary; some contain sugar or MSG")

compound("doubanjiang", "Doubanjiang", [
    comp("soybeans", "certain", ev("standard", "doubanjiang composition",
         "doubanjiang is fermented soybean and chili paste")),
    comp("chili-peppers", "certain", ev("standard", "doubanjiang composition")),
    comp("wheat-flour", "variable", ev("standard", "doubanjiang fermentation varies",
         "some styles use wheat flour in the fermentation (e.g. broad bean pastes with flour)")),
    comp("salt", "certain", ev("standard", "doubanjiang composition")),
], composition_complete=False,
    note="pixian doubanjiang uses broad beans; ingredient lists vary on wheat")

compound("black-bean-sauce", "Black bean sauce", [
    comp("soybeans", "certain", ev("standard", "black bean sauce composition",
         "fermented black soybeans are the base")),
    comp("wheat-flour", "variable", ev("standard", "black bean sauce composition varies",
         "some brands add wheat flour as binder")),
    comp("garlic", "typical", ev("standard", "black bean sauce composition")),
    comp("sugar", "typical", ev("standard", "black bean sauce composition")),
    comp("salt", "typical", ev("standard", "black bean sauce composition")),
    comp("soybean-oil-refined", "typical", ev("standard", "black bean sauce composition")),
], composition_complete=False,
    note="salted fermented black beans; brand formulations vary")

compound("shrimp-paste", "Shrimp paste", [
    comp("shrimp-part", "certain", ev("standard", "shrimp paste composition",
         "shrimp paste is fermented ground shrimp and salt")),
    comp("salt", "certain", ev("standard", "shrimp paste composition")),
], composition_complete=True,
    note="kapi/belacan/trasi: regional names for the same fermented shrimp product")

compound("thai-curry-paste", "Thai curry paste", [
    comp("chili-peppers", "certain", ev("standard", "thai curry paste composition")),
    comp("spices", "certain", ev("standard", "thai curry paste composition",
         "lemongrass, galangal, coriander root and kaffir lime are the aromatics")),
    comp("garlic", "typical", ev("standard", "thai curry paste composition")),
    comp("shrimp-paste", "typical", ev("standard", "thai curry paste composition",
         "most commercial and traditional pastes contain shrimp paste (kapi); "
         "vegan pastes exist — check the brand")),
], composition_complete=False,
    note="color and heat vary by curry type (red/green/yellow)")

compound("satay", "Satay", [
    comp("peanuts-part", "certain", ev("standard", "satay composition",
         "satay is grilled skewered meat with peanut sauce")),
    comp("chicken", "typical", ev("standard", "satay composition",
         "chicken is the most common satay meat; beef, pork and lamb exist")),
    comp("soy-sauce", "typical", ev("standard", "satay marinade",
         "marinades commonly use soy sauce, turmeric and lemongrass")),
], composition_complete=False,
    note="generic satay: meat species and marinade vary by vendor")

compound("peanut-sauce", "Peanut sauce", [
    comp("peanuts-part", "certain", ev("standard", "peanut sauce composition")),
    comp("coconut-milk", "typical", ev("standard", "peanut sauce composition")),
    comp("soy-sauce", "typical", ev("standard", "peanut sauce composition",
         "most recipes include soy sauce or tamari")),
    comp("sugar", "typical", ev("standard", "peanut sauce composition")),
    comp("salt", "typical", ev("standard", "peanut sauce composition")),
], composition_complete=True,
    note="satay sauce / gado-gado sauce")

compound("mole", "Mole", [
    comp("chili-peppers", "certain", ev("standard", "mole composition",
         "dried chiles are the base of every mole")),
    comp("chocolate", "typical", ev("standard", "mole composition",
         "mexican chocolate or cocoa is typical of mole poblano")),
    comp("peanuts-part", "typical", ev("standard", "mole composition",
         "peanuts are a common thickener in mole poblano and almond-based moles exist")),
    comp("sesame-seeds", "typical", ev("standard", "mole composition",
         "sesame is a standard garnish and thickener for mole poblano")),
    comp("sugar", "typical", ev("standard", "mole composition")),
    comp("spices", "certain", ev("standard", "mole composition")),
], composition_complete=False,
    allergen_overrides={"treeNuts": f("unknown", "standard", "mole composition varies",
                                      "almond-based moles exist; nuts vary by recipe")},
    note="generic mole: recipes differ radically by family and region")

compound("aioli", "Aioli", [
    comp("garlic", "certain", ev("standard", "aioli composition",
         "traditional aioli is garlic and olive oil emulsion")),
    comp("olive-oil", "certain", ev("standard", "aioli composition")),
    comp("egg", "certain", ev("standard", "aioli composition",
         "modern/provencal aioli adds egg yolk as emulsifier")),
], composition_complete=True,
    note="garlic mayonnaise: always contains raw egg in the modern form")

compound("hollandaise", "Hollandaise", [
    comp("egg", "certain", ev("standard", "hollandaise composition",
         "hollandaise is an emulsion of egg yolk and butter")),
    comp("butter", "certain", ev("standard", "hollandaise composition")),
    comp("lemon-juice", "typical", ev("standard", "hollandaise composition")),
], composition_complete=True,
    note="contains raw or lightly cooked egg")

compound("bechamel", "Bechamel", [
    comp("milk", "certain", ev("standard", "bechamel composition",
         "bechamel is milk thickened with a flour-butter roux")),
    comp("wheat-flour", "certain", ev("standard", "bechamel composition")),
    comp("butter", "typical", ev("standard", "bechamel composition")),
], composition_complete=True,
    note="white sauce; the classic French roux is wheat flour and butter")

compound("fresh-pasta", "Fresh pasta", [
    comp("durum-wheat-flour", "certain", ev("standard", "fresh pasta composition",
         "fresh pasta is durum wheat flour or semolina")),
    comp("egg", "certain", ev("standard", "fresh pasta composition",
         "egg is the defining difference from dried pasta")),
], composition_complete=True,
    note="pasta fresca: flour + egg")

compound("wonton-wrappers", "Wonton wrappers", [
    comp("wheat-flour", "certain", ev("standard", "wonton wrapper composition")),
    comp("water", "certain", ev("standard", "wonton wrapper composition")),
    comp("egg", "variable", ev("standard", "wonton wrapper composition varies",
         "traditional hong kong wrappers contain egg (alkaline noodles); "
         "shanghai-style are often egg-free")),
    comp("salt", "certain", ev("standard", "wonton wrapper composition")),
], composition_complete=False,
    note="check the label for egg; wheat is always present")

compound("gyoza-skins", "Gyoza skins", [
    comp("wheat-flour", "certain", ev("standard", "gyoza skin composition")),
    comp("water", "certain", ev("standard", "gyoza skin composition")),
    comp("salt", "certain", ev("standard", "gyoza skin composition")),
], composition_complete=True,
    synonyms=["dumpling wrappers", "dumpling skins", "potsticker wrappers"],
    note="gyoza/dumpling/potsticker wrappers are typically egg-free wheat dough")

compound("gnocchi", "Gnocchi", [
    comp("potato", "typical", ev("standard", "gnocchi composition",
         "potato gnocchi is the most common form; flour-only variants exist")),
    comp("wheat-flour", "typical", ev("standard", "gnocchi composition")),
    comp("egg", "variable", ev("standard", "gnocchi composition varies",
         "some recipes bind with egg, others not")),
], composition_complete=False,
    note="check the label; wheat is present in most commercial gnocchi")

compound("orzo", "Orzo", [
    comp("durum-wheat-flour", "certain", ev("standard", "orzo composition",
         "orzo is durum wheat semolina pasta shaped like rice")),
], composition_complete=True,
    synonyms=["risoni"],
    note="risoni/orzo is pasta, not rice")

simple("khoya", "Khoya", "dairy", contains=["milk"], synonyms=["mawa", "khoa"],
       note="reduced milk solids used in indian sweets")

compound("tempeh", "Tempeh", [
    comp("soybeans", "certain", ev("standard", "tempeh composition",
         "tempeh is fermented whole soybeans bound by mycelium")),
], composition_complete=True,
    note="fermented soybean cake; check labels for grains in mixed tempeh")

compound("soy-milk", "Soy milk", [
    comp("soybeans", "certain", ev("standard", "soy milk composition")),
    comp("water", "certain", ev("standard", "soy milk composition")),
], composition_complete=True,
    synonyms=["soya milk"],
    note="plain soy milk; flavoured variants may add sugar or thickeners")
part("soya-flour", "Soya flour", "plant", contains=["soy"])
part("rice-flour", "Rice flour", "plant", gluten="free",
     note="rice contains no gluten grain")
simple("spelt", "Spelt", "plant", contains=["wheat"], gluten="contains",
       synonyms=["spelt flour", "dinkel wheat"],
       note="spelt is Triticum aestivum subsp. spelta, a wheat species")
simple("farro", "Farro", "plant", contains=["wheat"], gluten="contains",
       synonyms=["farro grain", "emmer wheat"],
       note="farro is emmer (Triticum dicoccum) or related Triticum species, all wheat")
part("wheat-starch", "Wheat starch", "plant", contains=["wheat"], gluten="unknown",
     note="wheat-derived and processed to remove gluten; FDA permits it in gluten-free-labeled "
          "foods, but a wheat allergy still avoids it (declared wheat ingredient)")
part("stock-additives", "Commercial stock additives (source varies)", "mineral",
     note="commercial stocks list unspecific additives; sources vary by brand")
part("lemon-zest", "Lemon zest", "plant")
part("vegetable-oil-blend", "Vegetable oil blend", "plant",
     note="blend of seed oils; specific blend varies by brand (refined oils are FDA-exempt from soy labeling)")

# ===========================================================================
# Derivation
# ===========================================================================

CONTAINS_INDEX = {}
for e in ENTRIES:
    if e["contains"]:
        CONTAINS_INDEX[e["key"]] = set(e["contains"])

def carried_allergens(component_key: str) -> set[str]:
    """Allergens a certain/typical component carries (directly)."""
    return CONTAINS_INDEX.get(component_key, set())


ENTRY_INDEX = {e["key"]: e for e in ENTRIES}
DIET_IMPLICATION_MEMO: dict[str, dict[str, str]] = {}


def diet_implication(key: str) -> dict[str, str]:
    """vegetarian/vegan/pescatarian states implied by a component entry.

    violated beats unknown beats allowed. Compounds recurse over their
    components; variable components demote allowed to unknown.
    """
    if key in DIET_IMPLICATION_MEMO:
        return DIET_IMPLICATION_MEMO[key]
    e = ENTRY_INDEX[key]
    out = {"vegetarian": "allowed", "vegan": "allowed", "pescatarian": "allowed"}
    if e["cls"] is not None:
        veg, ve, pes = CLASS_DIETS[e["cls"]]
        out = {"vegetarian": veg, "vegan": ve, "pescatarian": pes}
    elif e["components"]:
        ranks = {"allowed": 0, "unknown": 1, "violated": 2}
        best = {"vegetarian": "allowed", "vegan": "allowed", "pescatarian": "allowed"}
        for c in e["components"]:
            if c["certainty"] == "unknown":
                continue
            imp = diet_implication(c["key"])
            variable = c["certainty"] not in ("certain", "typical")
            for d in best:
                state = imp[d]
                if state == "allowed" and variable:
                    state = "unknown"          # variable component: presence varies
                if ranks[state] > ranks[best[d]]:
                    best[d] = state
        out = best
    DIET_IMPLICATION_MEMO[key] = out
    return out


def derive(entry: dict) -> dict:
    facts: dict = {}
    if entry["components"] is not None:
        facts["components"] = list(entry["components"])
    if entry["composition_complete"] is not None:
        facts["compositionComplete"] = entry["composition_complete"]
    if entry["note"]:
        facts["note"] = entry["note"]

    # --- allergens -----------------------------------------------------
    allergens: dict[str, dict] = {}
    for a in ALLERGENS:
        if a in entry["allergen_overrides"]:
            allergens[a] = entry["allergen_overrides"][a]
            continue
        if a in entry["contains"]:
            allergens[a] = f("contains", "standard", "FDA FALCPA major food allergens",
                             f"{entry['display']} is a source of this FDA major allergen (standard composition)")
    if entry["components"]:
        carrier_of: dict[str, str] = {}
        for c in entry["components"]:
            if c["certainty"] in ("certain", "typical"):
                for a in carried_allergens(c["key"]):
                    carrier_of.setdefault(a, c["key"])
        var_carrier_of: dict[str, str] = {}
        for c in entry["components"]:
            if c["certainty"] == "variable":
                for a in carried_allergens(c["key"]):
                    if a not in carrier_of:
                        var_carrier_of.setdefault(a, c["key"])
        certain_keys = [c["key"] for c in entry["components"] if c["certainty"] in ("certain", "typical")]
        for a in ALLERGENS:
            if a in allergens:
                continue
            if a in carrier_of:
                allergens[a] = f("contains", "standard", "compound composition",
                                 f"component '{carrier_of[a]}' is a certain or typical ingredient")
            elif a in var_carrier_of:
                allergens[a] = f("unknown", "standard", "compound composition varies",
                                 f"component '{var_carrier_of[a]}' is variable: some products carry this allergen, some do not")
            elif entry["composition_complete"]:
                allergens[a] = f("free", "standard", "compound composition",
                                 "closed composition from certain/typical components: " + ", ".join(certain_keys)
                                 + "; no source of this allergen")
            # composition not complete and no variable carrier: no fact -> fail closed
    if allergens:
        facts["allergens"] = allergens

    # --- gluten (separate property) --------------------------------------
    if entry["gluten_override"]:
        facts["gluten"] = entry["gluten_override"]
    elif entry["gluten"]:
        state = entry["gluten"]
        if state == "free":
            facts["gluten"] = f("free", "standard",
                                "gluten is the protein of wheat, barley and rye",
                                f"{entry['display']} contains no gluten grain")
        elif state == "contains":
            facts["gluten"] = f("contains", "standard",
                                "gluten is the protein of wheat, barley and rye",
                                f"{entry['display']} is gluten-bearing")
        else:
            facts["gluten"] = f("unknown", "standard", entry["gluten_note"] or "gluten status varies",
                                entry["gluten_note"])
    elif entry["components"]:
        carriers = set()
        for c in entry["components"]:
            if c["certainty"] in ("certain", "typical"):
                carriers |= carried_allergens(c["key"])
        gluten_carriers = sorted(carriers & GLUTEN_GRAINS)
        if entry["composition_complete"]:
            if gluten_carriers:
                facts["gluten"] = f("contains", "standard", "compound composition",
                                    f"gluten via certain/typical component '{gluten_carriers[0]}'")
            else:
                facts["gluten"] = f("free", "standard",
                                    "gluten is the protein of wheat, barley and rye",
                                    "closed composition (" + ", ".join(c["key"] for c in entry["components"])
                                    + "); no gluten grain")
        elif gluten_carriers:
            facts["gluten"] = f("contains", "standard", "compound composition",
                                f"gluten via certain/typical component '{gluten_carriers[0]}'")
        # else: no gluten fact -> fail closed

    # --- diets -------------------------------------------------------------
    diets: dict[str, dict] = {}
    if entry["cls"] is not None:
        veg, ve, pes = CLASS_DIETS[entry["cls"]]
        for diet, default in (("vegetarian", veg), ("vegan", ve), ("pescatarian", pes)):
            if diet in entry["diet_overrides"]:
                diets[diet] = entry["diet_overrides"][diet]
                continue
            diets[diet] = f(default, "standard", "diet composition standard",
                            f"{CLASS_DIET_NOTE[entry['cls']]} (diet fact: {default})")
    else:
        for diet in ("vegetarian", "vegan", "pescatarian"):
            if diet in entry["diet_overrides"]:
                diets[diet] = entry["diet_overrides"][diet]
        # else: no diet facts -> evaluation fails closed

    # glutenFree: derived from the gluten + wheat facts (never from the class)
    if "glutenFree" in entry["diet_overrides"]:
        diets["glutenFree"] = entry["diet_overrides"]["glutenFree"]
    elif "gluten" in facts:
        st = facts["gluten"]["state"]
        mapped = {"contains": "violated", "free": "allowed", "unknown": "unknown"}[st]
        diets["glutenFree"] = {"state": mapped, "evidence": facts["gluten"]["evidence"]}
    elif facts.get("allergens", {}).get("wheat", {}).get("state") == "contains":
        w = facts["allergens"]["wheat"]
        diets["glutenFree"] = {"state": "violated", "evidence": w["evidence"]}
    # else: omitted -> evaluation fails closed

    # dairyFree: mirror of the milk allergen
    if "dairyFree" in entry["diet_overrides"]:
        diets["dairyFree"] = entry["diet_overrides"]["dairyFree"]
    elif "milk" in entry["contains"]:
        diets["dairyFree"] = f("violated", "standard", "FDA FALCPA major food allergens",
                               f"{entry['display']} is a milk product")
    elif "milk" in facts.get("allergens", {}):
        m = facts["allergens"]["milk"]
        if m["state"] == "contains":
            diets["dairyFree"] = {"state": "violated", "evidence": m["evidence"]}
        elif m["state"] == "free":
            diets["dairyFree"] = {"state": "allowed", "evidence": m["evidence"]}
    if entry["cls"] in ("plant", "fungus", "mineral", "insect-product") and not entry["components"] \
            and "dairyFree" not in diets:
        diets["dairyFree"] = f("allowed", "standard", "diet composition standard",
                               f"{CLASS_DIET_NOTE[entry['cls']]} (no milk component)")
    if diets:
        facts["diets"] = diets

    if entry["forms"]:
        facts["forms"] = {
            fm["name"]: {k: fm[k] for k in ("allergens", "gluten", "diets") if k in fm}
            for fm in entry["forms"]
        }
    return facts


def build_identities() -> dict:
    ingredients = []
    for e in sorted(ENTRIES, key=lambda x: x["key"]):
        if e["kind"] == "part":
            continue
        identity = {
            "key": e["key"],
            "display": e["display"],
            "kind": e["kind"],
            "synonyms": sorted(set(e["synonyms"])),
        }
        if e["fdc"] is not None:
            identity["usdaFdcId"] = e["fdc"]["ref"].split(" ")[1]
            identity["usdaFdcRef"] = e["fdc"]["ref"] + " — " + (e["fdc"]["note"] or "")
        if e["key"] in APP_LOCAL_IDS:
            identity["appLocalIds"] = [str(APP_LOCAL_IDS[e["key"]])]
        if e["forms"]:
            identity["forms"] = [
                {"name": fm["name"], "matchNames": sorted(set(fm["matchNames"]))} for fm in e["forms"]
            ]
        if e["note"]:
            identity["note"] = e["note"]
        ingredients.append(identity)
    return {"version": 1, "ingredients": ingredients}


def build_facts() -> dict:
    facts = {}
    for e in sorted(ENTRIES, key=lambda x: x["key"]):
        facts[e["key"]] = derive(e)
    return {"version": 1, "facts": facts}


def validate(identities: dict, facts: dict) -> list[str]:
    problems: list[str] = []
    fact_keys = facts["facts"]
    names_index: dict[str, str] = {}

    def claim(name: str, key: str) -> None:
        if name in names_index and names_index[name] != key:
            problems.append(f"name '{name}' maps to both {names_index[name]} and {key}")
        names_index.setdefault(name, key)

    for ing in identities["ingredients"]:
        key = ing["key"]
        claim(key, key)
        claim(ing["display"].lower(), key)
        for syn in ing["synonyms"]:
            claim(syn.lower(), key)
        for form in ing.get("forms", []):
            for mn in form["matchNames"]:
                claim(mn.lower(), key)
        if key not in fact_keys:
            if key != "artisan-granola-bar":   # deliberate fail-closed exemplar
                problems.append(f"identity {key} has no facts entry")
        for form in ing.get("forms", []):
            fkey = fact_keys.get(key, {})
            if form["name"] not in fkey.get("forms", {}):
                problems.append(f"identity {key} form {form['name']} has no facts override")

    def check_fact(state_obj: dict, where: str) -> None:
        state = state_obj["state"]
        if state not in ("contains", "free", "unknown", "allowed", "violated"):
            problems.append(f"{where}: bad state '{state}'")
        if state != "unknown" and not state_obj.get("evidence"):
            problems.append(f"{where}: {state} fact lacks evidence")
        evd = state_obj.get("evidence")
        if evd and evd["kind"] not in EVIDENCE_KINDS:
            problems.append(f"{where}: bad evidence kind '{evd['kind']}'")
        # absence never rests on catalog or recipe evidence (a nutrient-catalog
        # mapping or a recipe occurrence is not proof of allergen absence)
        if state in ("free", "allowed") and evd and evd["kind"] in ("usda", "recipe"):
            problems.append(f"{where}: absence state '{state}' may not use '{evd['kind']}' evidence")

    for key, e in fact_keys.items():
        for a, obj in e.get("allergens", {}).items():
            if a not in ALLERGENS:
                problems.append(f"{key}.allergens: unknown allergen '{a}'")
            check_fact(obj, f"{key}.allergens.{a}")
        for d, obj in e.get("diets", {}).items():
            if d not in DIETS:
                problems.append(f"{key}.diets: unknown diet '{d}'")
            check_fact(obj, f"{key}.diets.{d}")
        if "gluten" in e:
            check_fact(e["gluten"], f"{key}.gluten")
        for form_name, form_facts in e.get("forms", {}).items():
            for a, obj in form_facts.get("allergens", {}).items():
                if a not in ALLERGENS:
                    problems.append(f"{key}.forms.{form_name}: unknown allergen '{a}'")
                check_fact(obj, f"{key}.forms.{form_name}.allergens.{a}")
            for d, obj in form_facts.get("diets", {}).items():
                if d not in DIETS:
                    problems.append(f"{key}.forms.{form_name}: unknown diet '{d}'")
                check_fact(obj, f"{key}.forms.{form_name}.diets.{d}")
            if "gluten" in form_facts:
                check_fact(form_facts["gluten"], f"{key}.forms.{form_name}.gluten")
        for c in e.get("components", []):
            if c["certainty"] not in CERTAINTIES:
                problems.append(f"{key}.components: bad certainty '{c['certainty']}'")
            if c["certainty"] != "unknown" and not c.get("evidence"):
                problems.append(f"{key}.components.{c['key']}: {c['certainty']} component lacks evidence")
            if c["key"] not in fact_keys:
                problems.append(f"{key}.components: component key '{c['key']}' does not resolve")
        # cycle check (path-based: shared DAG nodes are not cycles)
        path: set[str] = set()
        visited: set[str] = set()

        def dfs(k: str) -> None:
            if k in path:
                problems.append(f"component cycle at {k}")
                return
            if k in visited:
                return
            path.add(k)
            visited.add(k)
            for c in fact_keys.get(k, {}).get("components", []):
                if c["key"] in fact_keys:
                    dfs(c["key"])
            path.discard(k)

        dfs(key)

    # app local ids must be exactly the 50 core
    local_keys = {i["key"] for i in identities["ingredients"] if i.get("appLocalIds")}
    if len(local_keys) != 50:
        problems.append(f"expected 50 identities with appLocalIds, found {len(local_keys)}")
    return problems


# ===========================================================================
# Corpus coverage (programmatic, reproducible)
# ===========================================================================

ORIGINAL_BRANCHES = [
    "origin/fleet/fl-recipe-originals",
    "origin/fleet/fl-recipe-originals-2",
    "origin/fleet/fl-recipe-originals-3",
    "origin/fleet/fl-recipe-originals-4",
    "origin/fleet/fl-recipe-originals-5",
    "origin/fleet/fl-recipe-originals-6",
    "origin/fleet/fl-recipe-originals-7",
]


def originals_branches() -> list[str]:
    out = subprocess.run(["git", "branch", "-r", "--format=%(refname:short)"],
                         cwd=REPO, capture_output=True, text=True, check=True).stdout.splitlines()
    return sorted(b for b in out if "fl-recipe-originals" in b)


def corpus_ingredient_names() -> dict:
    """Collect ingredient names from the originals branches and the bundled app data."""
    names: dict[str, set[str]] = {}

    def add(name: str, src: str) -> None:
        n = name.strip().lower()
        if n:
            names.setdefault(n, set()).add(src)

    def walk_strings(node, out: list) -> None:
        if isinstance(node, str):
            out.append(node)
        elif isinstance(node, list):
            for item in node:
                walk_strings(item, out)
        elif isinstance(node, dict):
            for v in node.values():
                walk_strings(v, out)

    for branch in originals_branches():
        try:
            paths = subprocess.run(
                ["git", "ls-tree", "-r", "--name-only", branch],
                cwd=REPO, capture_output=True, text=True, check=True).stdout.splitlines()
        except subprocess.CalledProcessError:
            print(f"note: branch {branch} unavailable", file=sys.stderr)
            continue
        for p in paths:
            if "/data/recipes/originals/" in p and p.endswith(".json") and "/tables/" not in p:
                raw = subprocess.run(["git", "show", f"{branch}:{p}"],
                                     cwd=REPO, capture_output=True, text=True, check=True).stdout
                try:
                    doc = json.loads(raw)
                except json.JSONDecodeError:
                    print(f"note: unparseable {branch}:{p}", file=sys.stderr)
                    continue
                ingredients = doc.get("ingredients", []) if isinstance(doc, dict) else []
                for ing in ingredients:
                    if isinstance(ing, dict) and ing.get("name"):
                        add(ing["name"], f"{branch}:{p}")
    # bundled app data: core ingredient names + compound terms in recipe steps
    data = json.loads((REPO / "apps/ios/Resources/data.json").read_text())
    for _key, vals in data.get("ingredients", {}).items():
        if isinstance(vals, list) and vals:
            add(str(vals[0]).replace("_", " "), "bundled:core")
    texts: list[str] = []
    walk_strings(data.get("recipes", []), texts)
    compound_terms = [
        "soy sauce", "worcestershire sauce", "pesto", "stock cube", "bouillon",
        "naan", "flatbread", "tortilla", "taco shells", "breadcrumbs", "hummus",
        "pitta", "pita", "chorizo", "halloumi", "paneer", "miso", "tamari",
        "gremolata", "raita", "spicy mayo", "chilli sauce", "chili sauce",
        "tomato paste", "tomato sauce", "curry powder", "garam masala",
        "cream cheese", "fish sauce", "oyster sauce", "sriracha", "harissa",
        "mayonnaise", "tahini", "tofu", "kimchi", "parmesan", "feta", "ricotta",
        "corn tortilla", "flour tortilla", "egg noodles", "rice noodles",
        "couscous", "bulgur", "polenta", "semolina", "lard", "gelatin", "gelatine",
    ]
    for text in texts:
        low = text.lower()
        for term in compound_terms:
            if term in low:
                add(term, "bundled:steps")
    return names


# Names resolved via synonyms must cover every corpus name that is a compound
# product; the remaining names are simple foods deliberately left unseeded
# (they resolve to unknown and the app asks). This list is the classification
# record for those simple foods.
SIMPLE_UNSEEDED = {
    "achiote seeds", "agave", "ancho powder", "apple juice", "apricots", "arrowroot",
    "baking powder", "baking soda", "bay leaves", "bean sprouts", "beetroot",
    "bicarbonate of soda", "biryani rice", "black beans (canned)", "black olives",
    "black tea", "blood orange", "bourbon", "brandy", "brown rice", "brown rice syrup",
    "buckwheat", "butternut squash", "cabbage", "cannellini beans", "canola oil",
    "cardamom", "cashew butter", "cauliflower", "cavolo nero", "cayenne", "chana dal",
    "cheddar", "cherries", "chickpea flour", "chili oil", "chili powder", "chives",
    "chocolate chips", "cilantro stems", "cinnamon", "cinnamon stick", "cloves",
    "coconut aminos", "coconut cream", "coconut oil", "coconut water", "cooked barley",
    "cooked quinoa", "coriander seeds", "corn kernels", "corn tortilla chips",
    "cornstarch", "cottage cheese", "cranberries", "cream of coconut", "crème fraîche",
    "cumin seeds", "currants", "dark chocolate", "dates", "dill", "dried apricots",
    "dried cranberries", "dry sherry", "duck breast", "duck legs", "edamame beans",
    "fennel", "fenugreek", "figs", "fresh chives", "fresh dill", "fruit juice",
    "garbanzo flour", "golden syrup", "gooseberries", "grape tomatoes", "green chiles",
    "green lentils", "green mango", "green tea", "herring", "horseradish", "hot dogs",
    "instant coffee", "jasmine tea", "kale", "kelp", "kidney beans", "leeks", "lemon peel",
    "lentils", "lime pickle", "macerated berries", "maple extract", "maple syrup",
    "marmite", "masa", "melon", "milk chocolate", "millet", "mint chutney", "molasses",
    "mussels", "mustard seeds", "nectarines", "nutritional yeast", "oat bran", "okra",
    "olives", "onion powder", "orange blossom water", "orange juice", "oregano",
    "panko-style corn flakes", "papaya", "parsnip", "peach", "peanut flour",
    "pearl onions", "pecans", "peppermint tea", "pickled ginger", "pickles",
    "pigeon peas", "pineapple juice", "pink salt", "pistachios", "plums", "pomegranate",
    "poppy seeds", "pork belly", "potato starch", "pumpkin", "purple sweet potato",
    "raisins", "raspberries", "red beans", "red cabbage", "red lentils", "rhubarb",
    "rose water", "rye", "saffron", "sage", "sake", "scallops", "sea beans", "seaweed",
    "sesame sticks", "shallots", "sherry vinegar", "soba", "sorrel", "soy curls",
    "sprouts", "squash", "star anise", "steel cut oats", "strawberries", "sun dried tomatoes",
    "sunflower seeds", "sweet chili sauce", "swiss chard", "tamarind", "tamarind paste",
    "tapioca", "tapioca starch", "tea leaves", "tequila", "thyme", "tomatillos",
    "turmeric", "turnip", "vanilla", "vanilla extract", "vegan mayo", "vinegar",
    "walnut halves", "watercress", "wheat berries", "white beans", "white chocolate",
    "white pepper", "whole wheat", "wine", "yuba", "zucchini blossoms",
}


def main() -> int:
    identities = build_identities()
    facts = build_facts()
    problems = validate(identities, facts)

    (ROOT / "identities.json").write_text(
        json.dumps(identities, indent=2, ensure_ascii=False) + "\n")
    (ROOT / "facts.json").write_text(
        json.dumps(facts, indent=2, ensure_ascii=False) + "\n")

    # coverage
    corpus = corpus_ingredient_names()
    name_to_key: dict[str, str] = {}

    def claim_name(name: str, key: str) -> None:
        name_to_key.setdefault(name.lower(), key)

    for ing in identities["ingredients"]:
        claim_name(ing["key"].replace("-", " "), ing["key"])
        claim_name(ing["display"], ing["key"])
        for syn in ing["synonyms"]:
            claim_name(syn.replace("_", " "), ing["key"])
        for form in ing.get("forms", []):
            for mn in form["matchNames"]:
                claim_name(mn, ing["key"])

    covered: dict[str, list[str]] = {}
    unseeded: dict[str, list[str]] = {}
    missing: list[str] = []
    for name in sorted(corpus):
        key = name_to_key.get(name) or name_to_key.get(name.rstrip("s")) \
            or name_to_key.get(name + "s")
        if key:
            covered.setdefault(key, []).append(name)
        elif name in SIMPLE_UNSEEDED:
            unseeded.setdefault(name, sorted(corpus[name]))
        else:
            missing.append(name)

    coverage = {
        "version": 1,
        "generatedBy": "data/ingredient-facts/tools/build_dataset.py",
        "originalsBranches": originals_branches(),
        "counts": {
            "identities": len(identities["ingredients"]),
            "factEntries": len(facts["facts"]),
            "corpusDistinctNames": len(corpus),
            "coveredCorpusNames": sum(len(v) for v in covered.values()),
            "simpleUnseededNames": sum(len(v) for v in unseeded.values()),
        },
        "coveredCompoundIdentities": {k: sorted(set(v)) for k, v in sorted(covered.items())},
        "simpleUnseeded": {k: sorted(set(v)) for k, v in sorted(unseeded.items())},
    }
    (ROOT / "coverage.json").write_text(
        json.dumps(coverage, indent=2, ensure_ascii=False) + "\n")

    print("identities:", len(identities["ingredients"]))
    print("fact entries:", len(facts["facts"]))
    print("corpus names:", len(corpus),
          "| covered:", sum(len(v) for v in covered.values()),
          "| simple-unseeded:", sum(len(v) for v in unseeded.values()))
    if missing:
        print("UNCLASSIFIED corpus names (neither covered nor in SIMPLE_UNSEEDED):")
        for m in missing:
            print("  -", m)
    if problems:
        print("VALIDATION PROBLEMS:")
        for p in problems:
            print("  -", p)
        return 1
    print("dataset OK")
    return 0 if not missing else 2


if __name__ == "__main__":
    sys.exit(main())
