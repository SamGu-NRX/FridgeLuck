#!/usr/bin/env python3
"""Legacy recipe audit for FridgeLuck's bundled data.json.

Reads apps/ios/Resources/data.json (166 legacy positional recipes) and
data/recipes/quarantine.jsonl, then checks every legacy recipe for six
failure modes:

  (a) a food named in the title or steps (meats, fish, shellfish, nuts,
      dairy, eggs, gluten grains, and the recipe's headline ingredients)
      with no matching ingredient line -> hide
  (b) a diet or allergen-free tag contradicted by the title, steps or
      lines (vegan with anchovy, vegetarian with chicken stock,
      gluten-free with pasta or flour) -> hide
  (c) required ingredients totalling implausibly little or much for the
      servings -> review only
  (d) sodium per serving above 2,300 mg -> review only
  (e) a BBC Good Food or other third-party source -> review only
  (f) already in data/recipes/quarantine.jsonl -> hide

Output: data/recipes/legacy-audit.jsonl, one line per legacy recipe that
fails (a), (b) or (f):

  {"legacy_id": <int>, "title": <str>, "verdict": "hide",
   "reasons": [<str>, ...], "evidence": [<str>, ...]}

Checks (c), (d) and (e) never hide; they are printed for REPORT.md as
"review" findings.

No model calls: every check is a small curated term list with synonyms,
defined below with comments. The term lists are judgment, not
measurement, and the hide verdicts they produce were hand-checked
against the recipe text; the confirmed false positives are recorded in
DROPPED_FALSE_POSITIVES at the bottom of this file so regeneration is
deterministic and the record of each drop travels with the rules.
"""

from __future__ import annotations

import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_JSON = REPO_ROOT / "apps" / "ios" / "Resources" / "data.json"
QUARANTINE_JSONL = REPO_ROOT / "data" / "recipes" / "quarantine.jsonl"
OUTPUT_JSONL = REPO_ROOT / "data" / "recipes" / "legacy-audit.jsonl"

# Sodium ceiling per serving: the FDA's Daily Value for sodium (2,300 mg).
SODIUM_REVIEW_LIMIT_MG = 2300
# (c) thresholds. These bands are judgment calls about what a sensible
# serving-sized meal weighs, not measurements of anything:
#   - under 60 g of required food per serving is a snack, not a meal;
#     every legacy recipe below it was missing most of its dish.
#   - over 1,200 g (1.2 kg) of required food per serving is beyond a
#     generous single serving for any dinner in this corpus.
#   - seasoning share: when oil/sauce/condiment lines carry more than
#     half the required mass (and more than 50 g), the recipe reads as a
#     sauce with garnish rather than a dish.
GRAMS_PER_SERVING_FLOOR = 60
GRAMS_PER_SERVING_CEILING = 1200
SEASONING_SHARE_LIMIT = 0.50
SEASONING_SHARE_MIN_GRAMS = 50

# ---------------------------------------------------------------------------
# Curated term list.
#
# FAMILY_TERMS maps a canonical food family to the surface forms that name
# it in titles, steps or ingredient lines. Matching is lowercase with word
# boundaries (r'\b...\b'), so 'nut' does not match 'nutmeg' and 'egg' does
# not match 'eggplant'. Multi-word forms are matched before single words so
# 'peanut butter' resolves to the peanut family, not dairy 'butter', and
# 'coconut milk' resolves to coconut milk, not dairy 'milk'.
#
# The list is deliberately small: it covers the allergen-relevant groups
# (the big-9 plus gluten grains) and the headline proteins. It is judgment
# about which names matter for safety, not a complete food ontology.
# ---------------------------------------------------------------------------

FAMILY_TERMS: dict[str, list[str]] = {
    # --- meats ---
    "chicken": ["chicken", "chicken breast", "chicken thigh", "poultry"],
    "beef": ["beef", "ground beef", "minced beef", "sirloin", "ribeye", "brisket", "braising steak"],  # 'steak' alone removed: fires on 'cauliflower steaks' (Jerk-style cauliflower, id 92)
    "pork": ["pork", "pork chop", "belly of pork", "pork loin"],
    "bacon": ["bacon", "lardon", "pancetta", "guanciale"],
    "ham": ["ham", "prosciutto", "gammon"],
    "sausage": ["sausage", "chorizo", "nduja", "salami", "pepperoni", "bratwurst", "hot dog", "cumberland"],
    "lamb": ["lamb", "mutton", "lamb shoulder", "lamb leg"],
    "turkey": ["turkey"],
    "duck": ["duck"],
    "meatball": ["meatball", "kofta"],
    # 'meat' matches "season the meat"; bare 'mince' would also match
    # "mince the garlic", so only explicit meat phrases are listed here.
    "meat-generic": ["meat", "meat free", "minced meat"],
    # --- fish ---
    "salmon": ["salmon"],
    "tuna": ["tuna"],
    "cod": ["cod"],
    "anchovy": ["anchovy", "anchovies"],
    "sardine": ["sardine", "pilchard"],
    "mackerel": ["mackerel"],
    "white-fish": ["haddock", "pollock", "sea bass", "sea bream", "white fish", "fish fillet"],
    "fish-generic": ["fish", "fish sauce"],
    # --- shellfish ---
    "shrimp": ["shrimp", "prawn", "king prawn"],
    "crab": ["crab"],
    "lobster": ["lobster"],
    "clam": ["clam"],
    "mussel": ["mussel"],
    "oyster": ["oyster"],
    "scallop": ["scallop"],
    "squid": ["squid", "calamari"],
    "shellfish-generic": ["shellfish"],
    # --- nuts ---
    "peanut": ["peanut", "peanut butter", "nut butter", "groundnut", "satay"],  # 'nut butter' covers prose like 'some nut butters are thicker than others'
    "almond": ["almond"],
    "cashew": ["cashew"],
    "walnut": ["walnut"],
    "pecan": ["pecan"],
    "hazelnut": ["hazelnut", "filbert"],
    "pistachio": ["pistachio"],
    "macadamia": ["macadamia"],
    "brazil-nut": ["brazil nut"],
    "pine-nut": ["pine nut", "pignoli"],
    "nut-generic": ["nuts", "mixed nuts", "toasted nuts"],
    # --- dairy (coconut milk is matched first as its own phrase, so the
    # bare 'milk' term never absorbs it; 'butter beans' is a legume and is
    # matched first as its own family, so dairy 'butter' never absorbs it) ---
    "butter-bean": ["butter bean", "butter beans"],
    "coconut-milk": ["coconut milk", "coconut cream"],
    "cheese": [
        "cheese", "cheddar", "mozzarella", "parmesan", "parmigiano", "pecorino",
        "feta", "ricotta", "halloumi", "gouda", "gruyere", "goat cheese",
        "cream cheese", "mascarpone", "paneer",
    ],
    "milk": ["milk", "whole milk", "semi skimmed milk", "skimmed milk"],
    "cream": ["cream", "double cream", "single cream", "heavy cream", "sour cream", "soured cream", "creme fraiche"],
    "butter": ["butter", "ghee"],
    "yogurt": ["yogurt", "yoghurt"],
    "egg": ["egg", "eggs", "beaten egg", "egg white", "egg yolk"],
    "honey": ["honey"],
    # --- gluten grains ---
    "pasta": ["pasta", "spaghetti", "macaroni", "penne", "fusilli", "linguine", "tagliatelle", "rigatoni", "orzo", "pappardelle", "orecchiette", "gnocchi"],
    "noodle": ["noodle", "noodles", "ramen", "udon", "soba", "hokkien"],
    "bread": ["bread", "bun", "bap", "baguette", "sourdough", "ciabatta", "focaccia", "pitta", "pita", "crouton"],
    "flour": ["flour", "plain flour", "all purpose flour", "self raising flour", "wheat flour", "cornflour batter"],
    "tortilla": ["tortilla", "flatbread", "naan", "roti", "pita bread"],
    "wheat-generic": ["wheat", "bulgur", "couscous", "semolina", "spelt", "barley", "rye", "farro", "freekeh", "cracker"],
}

# Multi-word phrases first so the longest surface form wins; a matched
# phrase blanks out its span, so its inner words cannot fire a second,
# wrong family ('butter beans' cannot also fire dairy 'butter', 'coconut
# milk' cannot fire dairy 'milk'). Phrases that legitimately carry two
# signals ('egg noodle' is both egg and noodle) are listed in
# MULTI_FAMILY_PHRASES instead.
_ALL_TERMS: list[tuple[str, str]] = sorted(
    ((term, family) for family, terms in FAMILY_TERMS.items() for term in terms),
    key=lambda pair: (-len(pair[0]), pair[0]),
)

# A phrase that maps to more than one family ('egg noodle' carries the egg
# allergen and the gluten grain).
MULTI_FAMILY_PHRASES: list[tuple[str, set[str]]] = [
    ("egg noodle", {"egg", "noodle"}),
]

# Families that are animal-derived. Vegan contradicted by any of these;
# vegetarian contradicted by the meat/fish/shellfish subset only.
MEAT_FISH_SHELLFISH = set(
    ["chicken", "beef", "pork", "bacon", "ham", "sausage", "lamb", "turkey", "duck",
     "meatball", "meat-generic", "salmon", "tuna", "cod", "anchovy", "sardine",
     "mackerel", "white-fish", "fish-generic", "shrimp", "crab", "lobster", "clam",
     "mussel", "oyster", "scallop", "squid", "shellfish-generic"]
)
ANIMAL_FAMILIES = MEAT_FISH_SHELLFISH | {"cheese", "milk", "cream", "butter", "yogurt", "egg", "honey"}
# Families that are (or commonly carry) gluten. Oats are deliberately not
# listed: they are gluten-free by nature and only contaminated in handling.
GLUTEN_FAMILIES = {"pasta", "noodle", "bread", "flour", "tortilla", "wheat-generic"}
# Families whose lines are seasoning/condiment rather than the body of the
# dish; used by the (c) seasoning-share review signal.
SEASONING_FAMILIES = {
    "soy sauce", "sesame oil", "olive oil", "oil", "honey", "vinegar", "salt",
    "sugar", "hot sauce", "fish sauce", "mayonnaise", "mustard", "curry paste",
}

# Generic families stand in for their specific siblings: a salmon line
# satisfies a generic 'fish' mention, a chicken line satisfies 'meat', pine
# nuts satisfy 'nuts'. When flagging a missing generic family, it is
# suppressed if any specific sibling is already flagged or on a line.
FISH_SPECIFIC = {"salmon", "tuna", "cod", "anchovy", "sardine", "mackerel", "white-fish"}
MEAT_SPECIFIC = {"chicken", "beef", "pork", "bacon", "ham", "sausage", "lamb", "turkey", "duck", "meatball"}
NUT_SPECIFIC = {"peanut", "almond", "cashew", "walnut", "pecan", "hazelnut", "pistachio", "macadamia", "brazil-nut", "pine-nut"}
GENERIC_SIBLINGS = {
    "fish-generic": FISH_SPECIFIC,
    "meat-generic": MEAT_SPECIFIC,
    "nut-generic": NUT_SPECIFIC,
}

# Findings reviewed by hand against the full recipe text and dropped as
# false positives. Key = (legacy_id, family) for (a) missing_headline and
# (legacy_id, tag) for (b) tag_contradiction. The rule fired on real text
# but the text does not actually make the recipe misleading. Justifications
# reference the exact wording in the shipped steps.
DROPPED_FALSE_POSITIVES: dict[tuple[int, str], str] = {
    # (a) drops — a named food that is not actually a missing component.
    (16, "bread"): "steps say 'Serve on lettuce leaves or bread' - bread is one of two serving options, not a recipe component",
    (35, "cheese"): "steps end 'crumbled feta and pumpkin seeds, if you like' - explicitly optional serving suggestion",
    (35, "flour"): "steps say '(Use flour tortillas if that's what you have.)' - alternative for the corn tortilla line that IS present",
    (42, "tortilla"): "'Serve with basmati rice or naan bread' - naan is already covered by the recipe's bread line (id 15)",
    (53, "tortilla"): "'serve with rice, naan and a big dollop of mango chutney' - serving suggestion, not a component",
    (60, "tortilla"): "'Serve with the warm naan' - naan is covered by the recipe's bread line (id 15)",
    (100, "wheat-generic"): "'then serve with couscous and natural yogurt' - couscous is a serving suggestion, not part of the one-pot",
    (131, "bread"): "'Serve with crusty bread for dipping' - serving suggestion; the traybake itself is complete",
    (135, "tortilla"): "'Serve with warmed naan breads' - naan is covered by the recipe's bread line (id 15)",
    (140, "tortilla"): "'Serve with naan bread.' - naan is covered by the recipe's bread line (id 15)",
    (154, "bacon"): "fired on the BBC page's 'Choose your toppings' menu (bacon, poached egg, feta, ciabatta, yogurt); the shipped one-pot itself is beans/pepper/tomato and correctly vegan",
    (154, "bread"): "same toppings menu as bacon; core one-pot needs no bread",
    (154, "cheese"): "same toppings menu as bacon; core one-pot needs no feta",
    (154, "chicken"): "same toppings menu as bacon; core one-pot is vegetarian as tagged",
    (154, "cream"): "same toppings menu as bacon; no cream in the core one-pot",
    (154, "egg"): "same toppings menu as bacon ('Poached egg' topping); core one-pot is vegan as tagged",
    (154, "yogurt"): "same toppings menu as bacon ('Top with yogurt' option); core one-pot is vegan as tagged",
    # (b) drops — the tag is not actually contradicted.
    (15, "low_carb"): "sweet potato is an OPTIONAL line ('if using', 114 g); the required lines (salmon, broccoli, lemon, oil) carry no starch",
    (48, "low_carb"): "fired on 'roughly mash with a potato masher' - a tool name, not an ingredient",
    (54, "low_carb"): "'dust the chicken with flour' - a 1-tbsp dusting split over 2 servings is negligible carbohydrate, not a diet contradiction",
    (88, "low_carb"): "fired on 'potato masher' wording in the chickpea-crushing step - a tool name, not an ingredient",
    (133, "vegetarian"): "'if you're adding sausages to any portion' - an optional meat add-in for non-vegetarian portions; the shipped stew is vegetarian as tagged",
    (154, "low_carb"): "'bread' comes from the optional toppings menu (ciabatta), not the core one-pot",
    (154, "vegan"): "all animal foods flagged come from the optional toppings menu; the core one-pot is vegan as tagged",
    (154, "vegetarian"): "same toppings menu; core one-pot is vegetarian as tagged",
    (156, "low_carb"): "'Serve with baked or steamed potatoes' - serving suggestion; the cod-and-tomato dish itself fits low_carb",
    (49, "tortilla"): "'serve with basmati rice or naan bread' - naan is covered by the recipe's bread line (id 15)",
    (50, "low_carb"): "'Serve with brown or white basmati rice' - serving suggestion; the korma itself carries no starch",
    (55, "pasta"): "'Serve with vegetables or salad and some pasta or potatoes, if you like' - optional serving suggestion",
    (69, "pasta"): "'serve over rice or pasta' - serving suggestion, not a component of the cola-braised chicken",
    (69, "low_carb"): "'rice' and 'pasta' come from the same serving suggestion; the dish itself is cola-braised chicken",
    (92, "beef"): "fired on 'cauliflower steaks' - 'steak' names the cut of cauliflower here, not beef; the term is removed from the beef family as too ambiguous",
    (92, "vegetarian"): "same 'cauliflower steaks' wording; the recipe contains no beef",
    (102, "tortilla"): "'Serve with flatbread.' - serving suggestion; the chickpea soup itself is complete",
    (117, "tortilla"): "'serve with rice or tortilla wraps' - serving option, like the rice; the chilli itself is complete",
    (141, "honey"): "'the honey or sugar' - an either/or sweetener choice; the salad does not require honey",
    (163, "wheat-generic"): "fired on 'wrap up like a cracker in baking parchment' - a simile about packing, not a cracker ingredient",
}

# Diet tags present in data.json's tags array. The shipped tags array is
# ['quick', 'vegetarian', 'vegan', 'asian', 'breakfast', 'budget',
#  'comfort', 'mediterranean', 'mexican', 'high_protein', 'low_carb',
#  'one_pot'] - there is no gluten-free tag in the shipped file, so the
# gluten_free branch below is written for completeness and fires only if
# such a tag ever appears.
DIET_TAG_CONTRACTIONS = {
    "vegan": ANIMAL_FAMILIES,
    "vegetarian": MEAT_FISH_SHELLFISH,
    "gluten_free": GLUTEN_FAMILIES,
    "gluten-free": GLUTEN_FAMILIES,
    "low_carb": {"pasta", "noodle", "bread", "rice-staple", "flour", "tortilla", "potato-staple"},
}

# Staple families used by the low_carb contraction check. Rice and potato
# live in data.json's ingredient names rather than FAMILY_TERMS (they are
# not allergens), so they get their own families here.
STAPLE_INGREDIENT_NAMES = {
    "rice-staple": ["rice", "white rice", "brown rice", "basmati", "jasmine rice"],
    "potato-staple": ["potato", "potatoes", "new potatoes", "mashed potato"],
}

_SOURCE_LINE_RE = re.compile(r"[Ss]ource:\s*\S+")
_URL_RE = re.compile(r"https?://\S+")
_WORD_RE = re.compile(r"[a-z0-9']+")


def normalize_text(text: str) -> str:
    """Lowercase, strip Source lines and URLs, keep word characters."""
    text = _SOURCE_LINE_RE.sub(" ", text)
    text = _URL_RE.sub(" ", text)
    text = text.lower().replace("_", " ").replace("-", " ").replace("/", " ")
    return " ".join(_WORD_RE.findall(text))


def families_in_text(text: str, extra_families: dict[str, list[str]] | None = None) -> set[str]:
    """Return the food families whose terms appear as words in text.

    Matches longest-first and blanks each matched span, so a phrase beats
    its own inner words: 'butter beans' adds the butter-bean family without
    also adding dairy 'butter'.
    """
    all_terms = list(_ALL_TERMS)
    if extra_families:
        all_terms += sorted(
            ((term, family) for family, terms in extra_families.items() for term in terms),
            key=lambda pair: (-len(pair[0]), pair[0]),
        )
    all_terms += [(term, None) for term, _f in MULTI_FAMILY_PHRASES]
    all_terms.sort(key=lambda pair: (-len(pair[0]), pair[0]))
    consumed = normalize_text(text)
    found: set[str] = set()
    for term, family in all_terms:
        # Recipes write plurals ('peanuts', 'anchovies', 'egg noodles'), so
        # every term matches with or without a trailing s. Terms already
        # ending in s also try the singular so 'butter beans' covers
        # 'butter bean'.
        variants = [term, term[:-1]] if term.endswith("s") else [term, term + "s"]
        for variant in variants:
            pattern = re.compile(r"\b" + re.escape(variant) + r"\b")
            match = pattern.search(consumed)
            while match:
                if family:
                    found.add(family)
                else:
                    found |= next(fams for t, fams in MULTI_FAMILY_PHRASES if t == term)
                consumed = consumed[:match.start()] + " " * (match.end() - match.start()) + consumed[match.end():]
                match = pattern.search(consumed)
    return found


# Ingredient-name families for data.json's own names, so a headline
# ingredient that is not in the curated list (mushroom, courgette,
# chickpea, ...) still counts when the title names it.
_IGNORED_NAME_FAMILIES = {"water"}


def ingredient_name_family(name: str) -> str:
    return name.replace("_", " ").strip().lower()


def load_data() -> tuple[dict, list[dict]]:
    raw = json.loads(DATA_JSON.read_text())
    tags: list[str] = raw["tags"]
    ingredients: dict[int, dict] = {}
    for id_string, fields in raw["ingredients"].items():
        ingredients[int(id_string)] = {
            "id": int(id_string),
            "name": fields[0],
            # Per-100g values; sodium is grams per 100 g (RecipeBundleV2Loader
            # documents this convention).
            "sodium_g_per_100g": fields[7],
        }
    recipes = []
    for row in raw["recipes"]:
        rid, title, _time, servings, required, optional, instructions, bitmask = row
        recipes.append(
            {
                "id": rid,
                "title": title,
                "servings": servings,
                "required": [(int(i), float(g)) for i, g in required],
                "optional": [(int(i), float(g)) for i, g in optional],
                "instructions": instructions,
                "tags": [tags[i] for i in range(len(tags)) if bitmask >> i & 1],
            }
        )
    recipes.sort(key=lambda r: r["id"])
    return ingredients, recipes


FAMILY_DISPLAY: dict[str, str] = {}


def display(family: str) -> str:
    """Human phrase for a family slug ('rice-staple' -> 'rice')."""
    if family not in FAMILY_DISPLAY:
        FAMILY_DISPLAY[family] = re.sub(r"-(staple|generic)$", "", family)
    return FAMILY_DISPLAY[family]


def load_quarantined_legacy_ids() -> dict[int, str]:
    """Map legacy recipe ids to quarantine entries.

    quarantine.jsonl ids look like fl-seed-NNNN or fl-nhs-NNNN. The seed
    entries' rights_record.origin text names the bundled recipe id
    ("bundled recipe id N, '<title>'"); that number is the legacy recipe id
    in data.json. Entries with no bundled-id reference (the NHS rows) are
    corpus-only and are skipped.
    """
    quarantined: dict[int, str] = {}
    for line in QUARANTINE_JSONL.read_text().splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        blob = json.dumps(entry)
        match = re.search(r"bundled recipe id (\d+)", blob)
        if match:
            quarantined[int(match.group(1))] = entry["id"]
    return quarantined


def apply_drops(rid: int, families: set[str], kind: str, findings: dict) -> set[str]:
    """Split out hand-checked false positives; kept families are returned."""
    kept = set()
    for family in sorted(families):
        why = DROPPED_FALSE_POSITIVES.get((rid, family))
        if why:
            findings["dropped"].append({"kind": kind, "key": family, "why": why})
        else:
            kept.add(family)
    return kept


def check_recipe(recipe: dict, ingredients: dict, quarantined: dict) -> dict:
    """Run every check on one recipe; returns a findings dict."""
    rid = recipe["id"]
    title = recipe["title"]
    steps = recipe["instructions"]
    lines = recipe["required"] + recipe["optional"]
    line_ids = {i for i, _g in lines}
    line_names = [ingredients[i]["name"] for i in line_ids if i in ingredients]
    findings = {
        "hide_reasons": [],
        "hide_evidence": [],
        "review": [],  # (check_letter, message)
        "dropped": [],  # false positives suppressed after hand-check, with reasons
    }

    title_families = families_in_text(title, STAPLE_INGREDIENT_NAMES)
    steps_families = families_in_text(steps, STAPLE_INGREDIENT_NAMES)
    # Which family each existing line satisfies: a line satisfies both its
    # curated family (if any) and its own ingredient-name family.
    line_families: set[str] = set()
    for i in line_ids:
        if i not in ingredients:
            continue
        name = ingredient_name_family(ingredients[i]["name"])
        line_families |= families_in_text(name, STAPLE_INGREDIENT_NAMES)
        line_families.add(name)

    # ---- (a) missing headline food ------------------------------------
    # A family named in the title (always) or steps (for the allergen-
    # relevant animal/nut/dairy/gluten families only, to keep step-level
    # noise like "serve with bread" bounded) with no line in that family.
    # Optional lines count as lines: the app renders them.
    headline_from_title = title_families - line_families
    headline_from_title = {
        f for f in headline_from_title
        if not (f in GENERIC_SIBLINGS and
                (GENERIC_SIBLINGS[f] & headline_from_title or
                 GENERIC_SIBLINGS[f] & line_families))
    }
    headline_from_title = apply_drops(rid, headline_from_title, "missing_headline", findings)
    for family in sorted(headline_from_title):
        name = display(family)
        findings["hide_reasons"].append(
            f"missing_headline:{family} (title names '{name}', no {name} ingredient line)"
        )
        findings["hide_evidence"].append(f"title: {title}")
    steps_only_families = steps_families - line_families - headline_from_title
    steps_only_families = {
        f for f in steps_only_families
        if not (f in GENERIC_SIBLINGS and
                (GENERIC_SIBLINGS[f] & headline_from_title or
                 GENERIC_SIBLINGS[f] & line_families))
    }
    steps_only_families = apply_drops(rid, steps_only_families, "missing_headline", findings)
    for family in sorted(steps_only_families & (ANIMAL_FAMILIES | GLUTEN_FAMILIES)):
        if family in headline_from_title:
            continue
        excerpt = first_mention_excerpt(steps, family)
        name = display(family)
        findings["hide_reasons"].append(
            f"missing_headline:{family} (steps mention '{name}', no {name} ingredient line)"
        )
        findings["hide_evidence"].append(f"steps: ...{excerpt}...")

    # ---- (b) diet-tag contradiction ------------------------------------
    text_families = title_families | steps_families | line_families
    for tag in recipe["tags"]:
        contradicting = DIET_TAG_CONTRACTIONS.get(tag)
        if not contradicting:
            continue
        why = DROPPED_FALSE_POSITIVES.get((rid, tag))
        if why:
            findings["dropped"].append({"kind": "tag_contradiction", "key": tag, "why": why})
            continue
        hits = sorted(text_families & contradicting)
        if hits:
            shown = ", ".join(display(f) for f in hits)
            findings["hide_reasons"].append(
                f"tag_contradiction:{tag} (tagged {tag} but {shown} present in title, steps or lines)"
            )
            findings["hide_evidence"].append(f"tags: {', '.join(recipe['tags'])}")
            for family in hits:
                where = []
                if family in title_families:
                    where.append(f"title: {title}")
                if family in line_families:
                    names = ", ".join(
                        ingredients[i]["name"] for i in sorted(line_ids)
                        if i in ingredients and ingredient_name_family(ingredients[i]["name"]) == family
                    )
                    if names:
                        where.append(f"lines: {names}")
                if family in steps_families and not where:
                    where.append(f"steps: ...{first_mention_excerpt(steps, family)}...")
                findings["hide_evidence"].append(f"{family} <- {'; '.join(where)}")

    # ---- (c) implausible required mass ---------------------------------
    required_grams = sum(g for _i, g in recipe["required"])
    per_serving = required_grams / recipe["servings"] if recipe["servings"] else 0
    if per_serving < GRAMS_PER_SERVING_FLOOR:
        findings["review"].append((
            "c",
            f"required mass {required_grams:.0f} g = {per_serving:.0f} g/serving "
            f"(< {GRAMS_PER_SERVING_FLOOR} g floor, judgment band)",
        ))
    elif per_serving > GRAMS_PER_SERVING_CEILING:
        findings["review"].append((
            "c",
            f"required mass {required_grams:.0f} g = {per_serving:.0f} g/serving "
            f"(> {GRAMS_PER_SERVING_CEILING} g ceiling, judgment band)",
        ))
    seasoning_grams = sum(
        g for i, g in recipe["required"]
        if i in ingredients and ingredient_name_family(ingredients[i]["name"]) in SEASONING_FAMILIES
    )
    if required_grams and seasoning_grams / required_grams > SEASONING_SHARE_LIMIT and seasoning_grams > SEASONING_SHARE_MIN_GRAMS:
        findings["review"].append((
            "c",
            f"seasoning lines carry {seasoning_grams:.0f} g of {required_grams:.0f} g "
            f"required mass ({seasoning_grams / required_grams:.0%} > 50% band)",
        ))

    # ---- (d) sodium per serving ----------------------------------------
    # Matches the app's required-lines-only recompute convention
    # (RecipeBundleV2Loader / recipe-amounts packets): optional lines are
    # not counted. sodium_g_per_100g is grams of sodium per 100 g.
    sodium_mg = sum(
        g * ingredients[i]["sodium_g_per_100g"] / 100 * 1000
        for i, g in recipe["required"]
        if i in ingredients
    ) / recipe["servings"] if recipe["servings"] else 0
    if sodium_mg > SODIUM_REVIEW_LIMIT_MG:
        findings["review"].append((
            "d",
            f"sodium ~{sodium_mg:.0f} mg/serving (required lines; limit {SODIUM_REVIEW_LIMIT_MG} mg)",
        ))

    # ---- (e) third-party source ----------------------------------------
    domains = sorted({m.group(1).lower() for m in re.finditer(r"https?://([a-z0-9.-]+)", steps)})
    for domain in domains:
        label = "BBC Good Food" if "bbcgoodfood" in domain else domain
        findings["review"].append(("e", f"third-party source: {domain} ({label})"))

    # ---- (f) already quarantined ---------------------------------------
    if rid in quarantined:
        findings["hide_reasons"].append(
            f"quarantined:rights (quarantine.jsonl entry {quarantined[rid]})"
        )
        findings["hide_evidence"].append(f"quarantine.jsonl: {quarantined[rid]}")

    return findings


def first_mention_excerpt(steps: str, family: str, width: int = 70) -> str:
    words = normalize_text(steps)
    match = re.search(r"\b" + re.escape(family) + r"\b", words)
    if not match:
        # family names like 'rice-staple' never appear literally
        return words[:width]
    start = max(0, match.start() - width // 3)
    return words[start:start + width]


# ---------------------------------------------------------------------------
# Hand-checked false positives.
#
# Every hide verdict caused by (a) or (b) was read against the full recipe
# text. These rows are the ones the term list flagged that do not survive
# the read; each records why. Keys are legacy ids; the value must name the
# reason string prefix it drops and the human justification. Keeping the
# drops here (not in the report alone) keeps regeneration byte-identical
# and the review trail with the rules that caused them.
# ---------------------------------------------------------------------------
def audit() -> dict:
    ingredients, recipes = load_data()
    quarantined = load_quarantined_legacy_ids()
    counts = {"a": 0, "b": 0, "c": 0, "d": 0, "e": 0, "f": 0, "g": 0, "recipes": len(recipes)}
    review_rows = []
    hide_rows = []

    for recipe in recipes:
        findings = check_recipe(recipe, ingredients, quarantined)
        for letter, message in findings["review"]:
            counts[letter] += 1
            review_rows.append((recipe["id"], recipe["title"], letter, message))
        for drop in findings["dropped"]:
            counts["g"] += 1

        drops = findings["dropped"]
        kept_reasons, kept_evidence = [], []
        for reason, evidence in zip(findings["hide_reasons"], findings["hide_evidence"]):
            kind = (
                "missing_headline"
                if reason.startswith("missing_headline")
                else "tag_contradiction"
            )
            key = (
                reason.split(":")[1].split(" ")[0]
                if kind == "missing_headline"
                else reason.split(":")[1].split(" ")[0]
            )
            drop = next((d for d in drops if d["kind"] == kind and d["key"] == key), None)
            if drop:
                continue
            counts["f"] += 1 if reason.startswith("quarantined") else 0
            if reason.startswith("missing_headline"):
                counts["a"] += 1
            elif reason.startswith("tag_contradiction"):
                counts["b"] += 1
            kept_reasons.append(reason)
            kept_evidence.append(evidence)

        if kept_reasons:
            hide_rows.append(
                OrderedDict(
                    [
                        ("legacy_id", recipe["id"]),
                        ("title", recipe["title"]),
                        ("verdict", "hide"),
                        ("reasons", kept_reasons),
                        ("evidence", kept_evidence),
                        ("dropped_false_positives", drops),
                    ]
                )
            )
        elif drops:
            # Every automated finding was dropped on hand-check: the recipe
            # is not hidden, but the reviewed-away findings stay on record.
            review_rows.append(
                (
                    recipe["id"],
                    recipe["title"],
                    "g",
                    "; ".join(f"{d['kind']}:{d['key']} dropped - {d['why']}" for d in drops),
                )
            )

    return {
        "counts": counts,
        "hide_rows": hide_rows,
        "review_rows": review_rows,
        "ingredients": ingredients,
        "recipes": recipes,
    }


def write_output(result: dict) -> None:
    lines = []
    for row in result["hide_rows"]:
        lines.append(json.dumps(row, ensure_ascii=False))
    OUTPUT_JSONL.write_text("\n".join(lines) + ("\n" if lines else ""))


def main() -> int:
    result = audit()
    write_output(result)
    counts = result["counts"]
    print(
        f"recipes={counts['recipes']} hides={len(result['hide_rows'])} "
        f"(a)missing_headline={counts['a']} (b)tag_contradiction={counts['b']} "
        f"(c)mass={counts['c']} (d)sodium={counts['d']} "
        f"(e)source={counts['e']} (f)quarantined={counts['f']} "
        f"(g)dropped_after_handcheck={counts['g']}"
    )
    print(f"wrote {OUTPUT_JSONL.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
