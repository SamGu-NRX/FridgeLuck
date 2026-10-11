#!/usr/bin/env python3
"""Corpus BUILDER for suite C — self-test FIXTURE tooling only.

The files this script writes (fixtures/selftest/authored.json,
fixtures/selftest/composed.json, fixtures/selftest/rights_manifest.json)
are suite C self-test fixtures. They are NEVER scoring inputs: the suite
scores the repo's data/recipes corpus (data/recipes/corpus.jsonl,
data/recipes/originals/) or, when absent, the bundled catalog as the
honest baseline. See suite.py's module docstring.

What this does (and does not do, honestly):

- The BUNDLED catalog (apps/ios/Resources/data.json, 166 positional recipes;
  141 citing bbcgoodfood.com with no licence evidence) is NOT copied here.
  It is audited, not reused: SPEC 10's default is rewrite-as-original or
  remove, and rewriting its expression is a job for legal review, not for
  this suite to fake.

- The expansion corpus is ORIGINAL expression created for FridgeLuck: the
  hand-authored seed (corpus/authored.json) plus recipes composed from
  vetted culinary pairings (FRAMEWORKS x BASES x SIDES below — every
  pairing is a combination a cook would recognise: protein + sauce
  framework + starch/vegetable side). Titles, ingredient lines and steps
  are generated fresh from the grammar; no third-party text is copied.

- Quantity evidence: household measures resolve through the fixture
  conversions table (USDA-based gram weights, approximations recorded openly
  in that file) and each emitted line CARRIES its evidence (conversion_ref
  plus the resolved grams on the line, the schema data/recipes/SCHEMA.md
  defines). Gram amounts written directly into a recipe by the builder are
  kind=source_grams — never "weighed": "weighed" means measured on a scale
  with the measurement recorded in provenance, and a builder estimate can
  never claim that. No line invents a mass it cannot support.

- Safety language: recipes whose ingredient classes include flesh or egg
  carry explicit thermometer doneness language with the right target
  temperature (poultry 165F/74C, fish 145F/63C, pork 145F/63C with rest,
  eggs 160F/71C) — mirroring the linter's requirements.

- The rights manifest records, PER RECIPE: source, source type, origin,
  license (LicenseRef-FL-Original — original work created for this
  project), access date, license evidence pointer, and the six SPEC 3.5
  permissions. images=false reflects reality: no images ship with these
  fixtures.

Replay: python3 corpus_build.py  — deterministic, no RNG, fixed iteration
order; rewrites fixtures/selftest/composed.json and rights_manifest.json.

This builder is NOT run by suite.py: the corpus files are committed, and
the suite lints what is committed (so a corrupted fixture is caught, not
regenerated away).
"""

from __future__ import annotations

import json
from pathlib import Path

SUITE_DIR = Path(__file__).resolve().parent
FIXTURE_DIR = SUITE_DIR / "fixtures" / "selftest"
CORPUS_DIR = FIXTURE_DIR

ACCESS_DATE = "2026-10-11"

# ---------------------------------------------------------------------------
# vetted pairing grammar
# ---------------------------------------------------------------------------
# FRAMEWORKS: key -> (cuisine, title prefix, sauce lines [(name, value, unit,
# conversion_ref)], compatible base keys, compatible side keys)

FRAMEWORKS: dict[str, tuple] = {
    "miso-ginger": ("asian", "Miso-ginger", [
        ("miso", 1.5, "tbsp", "miso_tbsp"), ("rice vinegar", 1, "tbsp", "rice_vinegar_tbsp"),
        ("maple syrup", 1, "tbsp", "maple_syrup_tbsp"), ("ginger", 1, "tbsp", "ginger_tbsp"),
        ("garlic", 2, "clove", "garlic_clove")],
        ["chicken_thighs", "salmon", "cod", "tofu", "cauliflower", "mushrooms", "eggplant", "chickpeas"],
        ["white_rice", "brown_rice", "rice_noodles", "wheat_noodles", "steamed_broccoli", "cucumber_salad"]),
    "teriyaki": ("asian", "Teriyaki", [
        ("soy sauce", 2, "tbsp", "soy_sauce_tbsp"), ("maple syrup", 1.5, "tbsp", "maple_syrup_tbsp"),
        ("rice vinegar", 1, "tsp", "rice_vinegar_tsp"), ("ginger", 1, "tsp", "ginger_tsp"),
        ("garlic", 1, "clove", "garlic_clove")],
        ["chicken_thighs", "salmon", "tilapia", "tofu", "mushrooms", "sweet_potato"],
        ["white_rice", "brown_rice", "rice_noodles", "steamed_broccoli", "cabbage_slaw"]),
    "gochujang": ("asian", "Gochujang-glazed", [
        ("gochujang", 1.5, "tbsp", "gochujang_tbsp"), ("soy sauce", 1, "tbsp", "soy_sauce_tbsp"),
        ("maple syrup", 1, "tbsp", "maple_syrup_tbsp"), ("garlic", 2, "clove", "garlic_clove"),
        ("sesame oil", 1, "tsp", "sesame_oil_tsp")],
        ["chicken_thighs", "tofu", "cauliflower", "mushrooms", "green_beans_base"],
        ["white_rice", "brown_rice", "rice_noodles", "cucumber_salad"]),
    "peanut-coconut": ("asian", "Peanut-coconut", [
        ("peanut butter", 2, "tbsp", "peanut_butter_tbsp"), ("soy sauce", 1, "tbsp", "soy_sauce_tbsp"),
        ("rice vinegar", 1, "tbsp", "rice_vinegar_tbsp"), ("maple syrup", 1, "tbsp", "maple_syrup_tbsp"),
        ("ginger", 1, "tbsp", "ginger_tbsp")],
        ["chicken_thighs", "tofu", "chickpeas", "sweet_potato", "cauliflower", "tempeh"],
        ["white_rice", "brown_rice", "rice_noodles", "cabbage_slaw"]),
    "tomato-basil": ("italian", "Tomato-basil", [
        ("canned tomatoes", 1, "cup", "canned_tomatoes_cup"), ("garlic", 2, "clove", "garlic_clove"),
        ("olive oil", 1, "tbsp", "olive_oil_tbsp"), ("basil", 2, "tbsp", "basil_tbsp")],
        ["cod", "chicken_breast", "white_beans", "chickpeas", "cauliflower", "eggplant", "mushrooms", "paneer"],
        ["pasta", "orzo", "polenta", "roasted_potatoes", "wilted_spinach"]),
    "salsa-verde": ("italian", "Salsa-verde", [
        ("parsley", 3, "tbsp", "parsley_tbsp"), ("olive oil", 2, "tbsp", "olive_oil_tbsp"),
        ("lemon", 0.5, "piece", "lemon_half"), ("garlic", 1, "clove", "garlic_clove"),
        ("capers", 1, "tbsp", "capers_tbsp")],
        ["salmon", "cod", "tilapia", "chicken_breast", "pork_chops", "white_beans", "cauliflower", "eggs"],
        ["roasted_potatoes", "orzo", "polenta", "wilted_spinach", "roasted_cauliflower"]),
    "lemon-herb": ("mediterranean", "Lemon-herb", [
        ("olive oil", 2, "tbsp", "olive_oil_tbsp"), ("lemon", 1, "piece", "lemon_piece"),
        ("oregano", 1, "tsp", "oregano_tsp"), ("garlic", 2, "clove", "garlic_clove")],
        ["chicken_thighs", "chicken_breast", "pork_chops", "salmon", "cod", "halloumi", "cauliflower", "potatoes_base"],
        ["couscous", "quinoa", "orzo", "roasted_potatoes", "roasted_cauliflower", "cucumber_salad", "pita"]),
    "harissa-yogurt": ("mediterranean", "Harissa-yogurt", [
        ("harissa", 1.5, "tbsp", "harissa_tbsp"), ("greek yogurt", 0.5, "cup", "greek_yogurt_cup"),
        ("lemon", 0.5, "piece", "lemon_half"), ("cumin", 0.5, "tsp", "cumin_tsp")],
        ["chicken_thighs", "cauliflower", "carrots_base", "sweet_potato", "chickpeas", "halloumi"],
        ["couscous", "quinoa", "pita", "roasted_cauliflower", "cucumber_salad"]),
    "tahini-lemon": ("mediterranean", "Tahini-lemon", [
        ("tahini", 3, "tbsp", "tahini_tbsp"), ("lemon", 1, "piece", "lemon_piece"),
        ("garlic", 1, "clove", "garlic_clove"), ("olive oil", 1, "tbsp", "olive_oil_tbsp")],
        ["cauliflower", "eggplant", "chickpeas", "white_beans", "tofu", "cod", "mushrooms"],
        ["quinoa", "couscous", "pita", "cucumber_salad", "wilted_spinach"]),
    "cumin-lime": ("mexican", "Cumin-lime", [
        ("olive oil", 1, "tbsp", "olive_oil_tbsp"), ("cumin", 1.5, "tsp", "cumin_tsp"),
        ("lime", 1, "piece", "lime_piece"), ("garlic", 2, "clove", "garlic_clove")],
        ["shrimp", "chicken_thighs", "black_beans", "cauliflower", "sweet_potato", "tofu"],
        ["tortillas", "brown_rice", "cabbage_slaw", "corn", "roasted_sweet_potato"]),
    "smoky-tomato-chipotle": ("mexican", "Smoky tomato-chipotle", [
        ("canned tomatoes", 1, "cup", "canned_tomatoes_cup"), ("chipotle", 1, "tbsp", "chipotle_tbsp"),
        ("cumin", 0.5, "tsp", "cumin_tsp"), ("garlic", 2, "clove", "garlic_clove"),
        ("olive oil", 1, "tbsp", "olive_oil_tbsp")],
        ["chicken_thighs", "black_beans", "kidney_beans", "cauliflower", "sweet_potato", "eggs"],
        ["tortillas", "brown_rice", "cabbage_slaw", "corn"]),
    "tikka": ("indian", "Tikka-spiced", [
        ("greek yogurt", 0.5, "cup", "greek_yogurt_cup"), ("garam masala", 2, "tsp", "garam_masala_tsp"),
        ("turmeric", 0.5, "tsp", "turmeric_tsp"), ("garlic", 2, "clove", "garlic_clove"),
        ("ginger", 1, "tbsp", "ginger_tbsp"), ("lemon", 0.5, "piece", "lemon_half")],
        ["chicken_breast", "cauliflower", "paneer", "sweet_potato", "mushrooms"],
        ["brown_rice", "white_rice", "quinoa", "roasted_cauliflower", "wilted_spinach"]),
    "coconut-curry": ("indian", "Coconut-curry", [
        ("coconut milk", 1, "cup", "coconut_milk_cup"), ("curry powder", 1, "tbsp", "curry_powder_tbsp"),
        ("ginger", 1, "tbsp", "ginger_tbsp"), ("garlic", 3, "clove", "garlic_clove"),
        ("lime", 0.5, "piece", "lime_half")],
        ["chickpeas", "lentils", "cauliflower", "eggplant", "cod", "chicken_thighs", "tofu", "spinach_base"],
        ["brown_rice", "white_rice", "quinoa", "roasted_sweet_potato", "wilted_spinach"]),
    "smoky-spice-rub": ("american", "Smoky-spice", [
        ("smoked paprika", 1, "tbsp", "smoked_paprika_tbsp"), ("brown sugar", 1, "tbsp", "brown_sugar_tbsp"),
        ("garlic", 2, "clove", "garlic_clove"), ("black pepper", 0.5, "tsp", "black_pepper_tsp")],
        ["chicken_thighs", "pork_chops", "cauliflower", "mushrooms", "sweet_potato", "tofu"],
        ["mashed_potatoes", "roasted_potatoes", "cabbage_slaw", "corn", "steamed_broccoli"]),
    "blackened": ("american", "Blackened", [
        ("smoked paprika", 2, "tsp", "smoked_paprika_tsp"), ("thyme", 1, "tsp", "thyme_tsp"),
        ("garlic", 2, "clove", "garlic_clove"), ("chili flakes", 0.5, "tsp", "chili_flakes_tsp"),
        ("olive oil", 1, "tbsp", "olive_oil_tbsp")],
        ["tilapia", "cod", "chicken_breast", "cauliflower", "mushrooms"],
        ["white_rice", "mashed_potatoes", "cabbage_slaw", "steamed_broccoli", "corn"]),
}

# BASES: key -> descriptor. kind: "household" (resolves via the fixture
# conversions table) or "grams" (a builder-written gram amount — emitted as
# kind=source_grams; a builder constant is NEVER labeled "weighed",
# which means measured on a scale with the measurement recorded).
BASES: dict[str, dict] = {
    "chicken_thighs": {"title": "chicken thighs", "name": "chicken thighs", "kind": "household",
                       "value": 3, "unit": "piece", "conv": "chicken_thigh_piece",
                       "method": "roast", "safety": "poultry"},
    "chicken_breast": {"title": "chicken breasts", "name": "chicken breast", "kind": "household",
                       "value": 2, "unit": "piece", "conv": "chicken_breast_piece",
                       "method": "pan-fry", "safety": "poultry"},
    "salmon": {"title": "salmon", "name": "salmon fillets", "kind": "household",
               "value": 2, "unit": "fillet", "conv": "salmon_fillet",
               "method": "pan-fry", "safety": "fish"},
    "cod": {"title": "cod", "name": "cod fillets", "kind": "household",
            "value": 2, "unit": "fillet", "conv": "cod_fillet",
            "method": "pan-fry", "safety": "fish"},
    "tilapia": {"title": "tilapia", "name": "tilapia fillets", "kind": "household",
                "value": 2, "unit": "fillet", "conv": "tilapia_fillet",
                "method": "pan-fry", "safety": "fish"},
    "shrimp": {"title": "shrimp", "name": "shrimp", "kind": "household",
               "value": 20, "unit": "piece", "conv": "shrimp_piece",
               "method": "stir-fry", "safety": "shellfish"},
    "pork_chops": {"title": "pork chops", "name": "pork chops", "kind": "household",
                   "value": 2, "unit": "chop", "conv": "pork_chop_piece",
                   "method": "pan-fry", "safety": "pork"},
    "tofu": {"title": "tofu", "name": "tofu", "kind": "household",
             "value": 0.5, "unit": "block", "conv": "tofu_block",
             "method": "stir-fry", "safety": None},
    "tempeh": {"title": "tempeh", "name": "tempeh", "kind": "grams", "value": 200,
               "method": "pan-fry", "safety": None},
    "chickpeas": {"title": "chickpeas", "name": "chickpeas", "kind": "household",
                  "value": 1.5, "unit": "cup", "conv": "chickpeas_cup",
                  "method": "roast", "safety": None},
    "black_beans": {"title": "black beans", "name": "black beans", "kind": "household",
                    "value": 1.5, "unit": "cup", "conv": "black_beans_cup",
                    "method": "simmer", "safety": None},
    "kidney_beans": {"title": "kidney beans", "name": "kidney beans", "kind": "household",
                     "value": 1.5, "unit": "cup", "conv": "kidney_beans_cup",
                     "method": "simmer", "safety": None},
    "white_beans": {"title": "white beans", "name": "white beans", "kind": "household",
                    "value": 1.5, "unit": "cup", "conv": "white_beans_cup",
                    "method": "simmer", "safety": None},
    "lentils": {"title": "lentils", "name": "red lentils", "kind": "grams", "value": 200,
                "method": "simmer", "safety": None, "simmer_min": 45},
    "cauliflower": {"title": "cauliflower", "name": "cauliflower", "kind": "household",
                    "value": 1, "unit": "head", "conv": "cauliflower_head",
                    "method": "roast", "safety": None},
    "eggplant": {"title": "eggplant", "name": "eggplant", "kind": "household",
                 "value": 1, "unit": "piece", "conv": "eggplant_piece",
                 "method": "roast", "safety": None},
    "mushrooms": {"title": "mushrooms", "name": "mushrooms", "kind": "household",
                  "value": 4, "unit": "cup", "conv": "mushrooms_cup",
                  "method": "pan-fry", "safety": None},
    "sweet_potato": {"title": "sweet potatoes", "name": "sweet potatoes", "kind": "household",
                     "value": 2, "unit": "piece", "conv": "sweet_potato_piece",
                     "method": "roast", "safety": None},
    "paneer": {"title": "paneer", "name": "paneer", "kind": "household",
               "value": 1.5, "unit": "cup", "conv": "paneer_cup",
               "method": "pan-fry", "safety": None},
    "halloumi": {"title": "halloumi", "name": "halloumi", "kind": "household",
                 "value": 6, "unit": "slice", "conv": "halloumi_slice",
                 "method": "pan-fry", "safety": None},
    "eggs": {"title": "eggs", "name": "eggs", "kind": "household",
             "value": 6, "unit": "piece", "conv": "egg_piece",
             "method": "skillet-eggs", "safety": "egg"},
    "green_beans_base": {"title": "green beans", "name": "green beans", "kind": "grams",
                         "value": 250, "method": "stir-fry", "safety": None},
    "carrots_base": {"title": "carrots", "name": "carrots", "kind": "household",
                     "value": 4, "unit": "piece", "conv": "carrot_piece",
                     "method": "roast", "safety": None},
    "potatoes_base": {"title": "potatoes", "name": "potatoes", "kind": "household",
                      "value": 3, "unit": "piece", "conv": "potato_piece",
                      "method": "roast", "safety": None},
    "spinach_base": {"title": "spinach", "name": "spinach", "kind": "household",
                     "value": 6, "unit": "cup", "conv": "spinach_cup",
                     "method": "simmer", "safety": None},
}

# SIDES: key -> (title fragment, ingredient lines [(name, value, unit, conv)], extra minutes)
SIDES: dict[str, tuple] = {
    "white_rice": ("rice", [("white rice", 1, "cup", "dry_rice_cup")], 20),
    "brown_rice": ("brown rice", [("brown rice", 1, "cup", "dry_brown_rice_cup")], 25),
    "quinoa": ("quinoa", [("quinoa", 0.75, "cup", "dry_quinoa_cup")], 20),
    "couscous": ("couscous", [("couscous", 1, "cup", "dry_couscous_cup"),
                              ("vegetable stock", 1, "cup", "veg_stock_cup")], 10),
    "orzo": ("orzo", [("orzo", 1, "cup", "orzo_cup"),
                      ("vegetable stock", 1.5, "cup", "veg_stock_cup")], 15),
    "pasta": ("pasta", [("pasta", 6, "cup", "pasta_cup")], 12),
    "rice_noodles": ("rice noodles", [("rice noodles", 2, "cup", "rice_noodles_cup")], 10),
    "wheat_noodles": ("noodles", [("wheat noodles", 2, "cup", "wheat_noodles_cup")], 10),
    "polenta": ("polenta", [("cornmeal", 0.5, "cup", "cornmeal_cup"),
                            ("vegetable stock", 2, "cup", "veg_stock_cup")], 20),
    "tortillas": ("tortillas", [("flour tortillas", 4, "piece", "tortilla_piece")], 5),
    "pita": ("pita", [("pita", 2, "piece", "pita_piece")], 5),
    "roasted_potatoes": ("roasted potatoes", [("potatoes", 2, "piece", "potato_piece"),
                                              ("olive oil", 1, "tbsp", "olive_oil_tbsp")], 35),
    "mashed_potatoes": ("mashed potatoes", [("potatoes", 3, "piece", "potato_piece"),
                                            ("butter", 1, "tbsp", "butter_tbsp"),
                                            ("milk", 0.25, "cup", "milk_cup")], 30),
    "roasted_sweet_potato": ("roasted sweet potatoes", [("sweet potatoes", 2, "piece", "sweet_potato_piece"),
                                                        ("olive oil", 1, "tbsp", "olive_oil_tbsp")], 35),
    "roasted_cauliflower": ("roasted cauliflower", [("cauliflower", 0.5, "head", "cauliflower_head"),
                                                    ("olive oil", 1, "tbsp", "olive_oil_tbsp")], 30),
    "steamed_broccoli": ("steamed broccoli", [("broccoli", 2, "cup", "broccoli_cup")], 8),
    "wilted_spinach": ("wilted spinach", [("spinach", 3, "cup", "spinach_cup"),
                                          ("olive oil", 1, "tsp", "olive_oil_tsp")], 5),
    "cabbage_slaw": ("lime slaw", [("cabbage", 2, "cup", "cabbage_cup"),
                                   ("lime", 0.5, "piece", "lime_half"),
                                   ("olive oil", 1, "tsp", "olive_oil_tsp")], 5),
    "cucumber_salad": ("cucumber salad", [("cucumber", 1, "piece", "cucumber_piece"),
                                          ("rice vinegar", 1, "tbsp", "rice_vinegar_tbsp")], 5),
    "corn": ("corn", [("corn", 1, "cup", "corn_cup")], 6),
}

# safety blocks per base: FSIS class key + safe minimum internal temperature.
# The linter requires steps on animal-flesh recipes to carry a structured
# safety check {class, temp_f, method=thermometer, source} (SPEC 3.1).
SAFETY_BLOCK = {
    "poultry": {"class": "meat_poultry", "temp_f": 165, "method": "thermometer",
                "source": "USDA FSIS safe minimum internal temperature chart"},
    "fish": {"class": "flesh_fish", "temp_f": 145, "method": "thermometer",
             "source": "USDA FSIS safe minimum internal temperature chart"},
    "shellfish": {"class": "flesh_shellfish", "temp_f": 145, "method": "thermometer",
                  "source": "USDA FSIS safe minimum internal temperature chart"},
    "pork": {"class": "meat_whole_cut_pork", "temp_f": 145, "method": "thermometer",
             "source": "USDA FSIS safe minimum internal temperature chart"},
    "egg": {"class": "egg", "temp_f": 160, "method": "thermometer",
            "source": "USDA FSIS safe minimum internal temperature chart"},
}
SAFETY_SENTENCE = {
    "poultry": "Poultry is done when an instant-read thermometer in the thickest piece reads 165\u00b0F (74\u00b0C).",
    "fish": "Fish is done when an instant-read thermometer reads 145\u00b0F (63\u00b0C) and the flesh flakes.",
    "shellfish": "Shrimp are done when an instant-read thermometer reads 145\u00b0F (63\u00b0C).",
    "pork": "Pork is done when an instant-read thermometer reads 145\u00b0F (63\u00b0C) with a 3-minute rest.",
    "egg": "Eggs are safe to serve once fully set, 160\u00b0F (71\u00b0C).",
}


def conv_grams(conv_ref: str, value: float, table: dict) -> float:
    return round(table[conv_ref]["grams_per_unit"] * value)


def _steps_for(base: dict, sauce_first: str, side_title: str, method: str,
               timings: dict) -> list[dict]:
    """Generate the step list; attach a structured FSIS safety check for
    animal-flesh/egg bases (the linter rejects prose-only doneness)."""
    key = base["safety"]
    safety = SAFETY_SENTENCE.get(key, "")
    safety_block = dict(SAFETY_BLOCK[key]) if key else None

    def cook_step(text: str, timer_min: int | None) -> dict:
        step: dict = {"text": text}
        if safety:
            step["text"] = f"{text} {safety}"
            step["safety"] = dict(safety_block)  # type: ignore[arg-type]
        if timer_min is not None:
            step["timer_min"] = timer_min
        return step

    s: list[dict] = []
    if method == "stir-fry":
        s.append({"text": f"Whisk the {sauce_first} with 2 tbsp of water in a small bowl."})
        s.append(cook_step(
            f"Get a wok or wide skillet very hot with the oil; stir-fry the "
            f"{base['name']} until the outside is seared, about {timings['base_min']} minutes.",
            timings["base_min"]))
        s.append({"text": "Add the sauce mixture and toss until it glazes everything, about 2 minutes."})
        s.append({"text": f"Serve over the {side_title}."})
    elif method == "roast":
        s.append({"text": "Heat the oven to 425\u00b0F (220\u00b0C)."})
        s.append({"text": f"Toss the {base['name']} with the sauce mixture and the oil on a sheet pan in a single layer."})
        s.append(cook_step(
            f"Roast until the thickest piece reaches temperature, about {timings['roast_min']} minutes."
            + (" Rest 5 minutes before serving." if key in ("poultry", "pork") else ""),
            timings["roast_min"]))
        s.append({"text": f"While the pan roasts, prepare the {side_title}."})
        s.append({"text": f"Serve hot from the pan with the {side_title}, scraping the pan juices over."})
    elif method == "simmer":
        s.append({"text": "Sizzle the sauce aromatics in the oil in a heavy pot for 1 minute."})
        s.append({"text": f"Add the {base['name']} and the sauce mixture; bring to a bare simmer."})
        s.append(cook_step(
            f"Simmer covered until everything is tender and the sauce has settled, "
            f"about {timings['simmer_min']} minutes.",
            timings["simmer_min"]))
        s.append({"text": f"Serve in deep bowls over the {side_title}."})
    elif method == "pan-fry":
        s.append({"text": f"Pat the {base['name']} dry and season with salt."})
        s.append(cook_step(
            f"Heat the oil in a skillet over medium-high; cook the {base['name']} "
            f"about {timings['base_min']} minutes per side as needed.",
            timings["base_min"]))
        s.append({"text": f"Plate over the {side_title} and spoon the pan juices on top."})
    else:  # skillet-eggs
        s.append({"text": f"Beat the {base['name']} with salt."})
        s.append(cook_step(
            "Cook in the butter or oil over medium heat, stirring, until fully set.",
            5))
        s.append({"text": f"Serve with the {side_title}."})
    return s


def compose() -> list[dict]:
    """Deterministically compose the expansion corpus."""
    table = json.loads((FIXTURE_DIR / "conversions.json").read_text())["conversions"]
    recipes: list[dict] = []
    seen_titles: set[str] = set()
    for fkey, (cuisine, prefix, sauce_lines, base_keys, side_keys) in FRAMEWORKS.items():
        for bkey in base_keys:
            base = BASES[bkey]
            for skey in side_keys:
                side_title, side_lines, side_min = SIDES[skey]
                title = f"{prefix} {base['title']} with {side_title}"
                if title in seen_titles:
                    continue
                seen_titles.add(title)

                ingredients: list[dict] = []
                if base["kind"] == "household":
                    ingredients.append({
                        "name": base["name"],
                        "qty": {"kind": "household", "value": base["value"],
                                "unit": base["unit"],
                                "grams": conv_grams(base["conv"], base["value"], table),
                                "conversion_ref": base["conv"]}})
                else:
                    ingredients.append({
                        "name": base["name"],
                        "qty": {"kind": "source_grams", "grams": base["value"]}})
                for name, value, unit, conv in sauce_lines:
                    ingredients.append({
                        "name": name,
                        "qty": {"kind": "household", "value": value, "unit": unit,
                                "grams": conv_grams(conv, value, table),
                                "conversion_ref": conv}})
                for name, value, unit, conv in side_lines:
                    ingredients.append({
                        "name": name,
                        "qty": {"kind": "household", "value": value, "unit": unit,
                                "grams": conv_grams(conv, value, table),
                                "conversion_ref": conv}})
                ingredients.append({"name": "salt",
                                    "qty": {"kind": "household", "value": 0.5, "unit": "tsp",
                                           "grams": 3, "conversion_ref": "salt_tsp"}})

                method = base["method"]
                if method == "roast":
                    roast_min = 12 + side_min + 10
                    timings = {"roast_min": roast_min}
                    minutes = 10 + roast_min
                elif method == "simmer":
                    simmer_min = base.get("simmer_min", 25) + side_min
                    timings = {"simmer_min": simmer_min}
                    minutes = 10 + simmer_min
                elif method == "stir-fry":
                    base_min = 5 if base["name"] == "shrimp" else 7
                    timings = {"base_min": base_min}
                    minutes = base_min + 6 + side_min
                elif method == "pan-fry":
                    base_min = 6
                    timings = {"base_min": base_min}
                    minutes = 8 + base_min * 2 + side_min
                else:  # skillet-eggs
                    timings = {"base_min": 5}
                    minutes = 8 + side_min

                # meal slots: quick egg recipes can be breakfast; otherwise lunch/dinner
                if method == "skillet-eggs":
                    slots = ["breakfast", "dinner"]
                elif minutes <= 25:
                    slots = ["lunch", "dinner"]
                else:
                    slots = ["dinner"]

                steps = _steps_for(base, sauce_first=f"{sauce_lines[0][0]} and {sauce_lines[1][0]}",
                                   side_title=side_title, method=method, timings=timings)

                recipes.append({
                    "rs_version": "1",
                    "id": f"comp-{fkey}-{bkey}-{skey}",
                    "title": title,
                    "cuisine": cuisine,
                    "meal_slots": slots,
                    "minutes": minutes,
                    "servings": 2,
                    "ingredients": ingredients,
                    "steps": steps,
                    "claims": [],
                    "source_ref": f"orig:composed:{fkey}:{bkey}:{skey}",
                    "provenance": "composed",
                })
    return recipes


def build_manifest(corpus: list[dict]) -> dict:
    """Rights manifest covering every corpus recipe (seed + composed)."""
    records: dict[str, dict] = {}
    for r in corpus:
        ref = r.get("source_ref", "")
        if ref.startswith("orig:authored:"):
            origin = "authored seed corpus: hand-written for FridgeLuck suite C on branch eval/suite-recipes"
        elif ref.startswith("orig:composed:"):
            origin = "composed original: generated from the vetted pairing grammar in corpus_build.py on branch eval/suite-recipes"
        else:
            # fail-closed: an unknown source_ref origin cannot be cleared here
            origin = ""
        records[ref] = {
            "source_id": ref,
            "source_type": "original",
            "origin": origin,
            "license": "LicenseRef-FL-Original",
            "access_date": ACCESS_DATE,
            "license_evidence": ("Original expression created for FridgeLuck evaluation fixtures; "
                                 "no third-party text copied. Provenance recorded per recipe via "
                                 "source_ref; builder replay: python3 corpus_build.py. See PR Proof section."),
            "permissions": {"text": True, "images": False, "modification": True,
                            "attribution": True, "caching": True, "offline_use": True},
        }
    return {"schema": "fl-rights-manifest/1", "records": records}


def main() -> None:
    authored = json.loads((FIXTURE_DIR / "authored.json").read_text())["recipes"]
    composed = compose()
    corpus = authored + composed
    manifest = build_manifest(corpus)
    (FIXTURE_DIR / "composed.json").write_text(
        json.dumps({"recipes": composed}, indent=2, ensure_ascii=False) + "\n")
    (FIXTURE_DIR / "rights_manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    bands: dict[str, int] = {}
    for r in corpus:
        for slot in r["meal_slots"]:
            bands[f"slot:{slot}"] = bands.get(f"slot:{slot}", 0) + 1
        bands[f"cuisine:{r['cuisine']}"] = bands.get(f"cuisine:{r['cuisine']}", 0) + 1
        m = r["minutes"]
        tb = "0-15" if m <= 15 else "16-30" if m <= 30 else "31-60" if m <= 60 else "60+"
        bands[f"time:{tb}"] = bands.get(f"time:{tb}", 0) + 1
    print(f"authored: {len(authored)}  composed: {len(composed)}  total: {len(corpus)}")
    for k in sorted(bands):
        print(f"  {k}: {bands[k]}")


if __name__ == "__main__":
    main()
