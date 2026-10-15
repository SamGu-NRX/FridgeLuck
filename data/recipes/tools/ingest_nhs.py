#!/usr/bin/env python3
"""Ingest NHS Healthier Families recipes (OGL v3.0) into the RS v1 corpus.

Source of rights: SOURCES.md section 2 — NHS Website Content is released under
the Open Government Licence v3.0 (quoted terms, retrieved 2026-10-11). Recipe
TEXT only (NHS images are excluded content). We adapt wording (safety
rephrasing, step splitting), so the adapted-content rule applies: the app's
source-credits surface carries "Contains public sector information licensed
under the Open Government Licence v3.0." and the adapted recipes are not
presented as NHS content in the app UI; the rights records keep the per-recipe
source URL as provenance.

Rights record (per SOURCES.md record template): source_id `nhs_website`,
source_type `government`, origin "NHS Website Content (Department of Health and
Social Care)", license `OGL-3.0`, access_date the retrieval date, six
permissions all true except `images` (false — ship no NHS photographs).

Evidence policy (SCHEMA.md section 2 — no mass invented):
- grams stated by NHS ("200g porridge oats", "2 x 400g tins") -> source_grams;
- household measures with a matching suite conversion_ref ("1 tbsp olive
  oil", "6 cloves garlic", "1 medium onion", "2 large eggs") -> household;
- everything else — ml liquids (no ml refs exist in the suite table), sizes
  that contradict the ref ("small onion" vs 'medium onion'), handfuls,
  thumb-sized pieces, whole spices — kind `unknown`, honestly unresolved.
- Selection rule: a recipe is ingested only when >=95% of its lines resolve
  (the corpus bar); skipped recipes are listed with reasons (they stay behind,
  quarantined from this corpus, nothing fail-open).

Claims: written only when the suite AllergenScanner verifies the claim AND no
unrecognized ingredient name could belong to the claim's domain (keyword
denylists over the raw NHS line text — e.g. paneer is invisible to the alias
table but is dairy). This is the same scanner-verification bar as the seeds
plus a recognition guard for scale.

Doneness (build_steps): NHS colour/time doneness clauses are rephrased to a
thermometer check at the strictest FSIS endpoint of the foods they cover,
taken from the recipe's own ingredients through food_safety.py (ground
poultry 165 F, whole-cut pork 145 F plus a 3-minute rest). Every step that
reheats carries its own 165 F check. Any required food still unchecked gets
a closing check that names it (165 F for a casserole). A page whose
converted steps fail food_safety.safety_violations is skipped, not ingested.

Modes:
    --measure  parse + classify + print selection and judgments; write nothing
    --write    ingest selected recipes, append to corpus.jsonl and the manifest

Usage:
    python3 data/recipes/tools/ingest_nhs.py --suite-dir <dir> --pages /tmp/nhs-pages --measure
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from html import unescape as html_unescape
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import composition  # noqa: E402
import food_safety  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"
C_FOR_F = {145: 63, 160: 71, 165: 74}  # Celsius as FoodSafety.gov rounds them
MANIFEST = REPO_ROOT / "data/recipes/rights_manifest.json"

BUILD_DATE = "2026-10-11"
FSIS_SOURCE = food_safety.FSIS_SOURCE
NHS_TERMS_URL = "https://www.nhs.uk/our-policies/terms-and-conditions/"
ID_TAG = "nhs"  # source-tag for fl-<source-tag>-<4 digits>; source_id is nhs_website
MIN_RESOLVE = 0.95

# ---------------------------------------------------------------------------
# ingredient-name normalization: UK terms -> suite-alias-friendly names,
# applied only where it is the same food (allergen-identical).
# ---------------------------------------------------------------------------
NAME_RULES: list[tuple[str, str]] = [
    # -- dairy --
    (r"\bgreek[- ]style natural yogh(?:urt|e?urt)\b", "greek yogurt"),
    (r"\bgreek (?:style )?yogh(?:urt|e?urt)\b", "greek yogurt"),
    (r"\b(?:0%|zero)?[- ]?fat greek yogurt\b", "greek yogurt"),
    (r"\b(?:natural|low[- ]fat natural)?\s?yogh(?:urt|e?urt)\b", "greek yogurt"),
    (r"\bsoya? yogh(?:urt|e?urt)\b", "soy yogurt"),
    (r"\bsemi[- ]skimmed milk\b", "milk"),
    (r"\bskimmed milk\b", "milk"),
    (r"\b1%\s*fat milk\b", "milk"),
    (r"\bdouble cream\b", "cream"),
    (r"\bsingle cream\b", "cream"),
    (r"\bsoured cream\b", "cream"),
    (r"\bsour cream\b", "cream"),
    (r"\bcreme fraiche\b", "cream"),
    (r"\bcre(?:me|ème)\s+fra[îi]che\b", "cream"),
    # -- eggs --
    (r"\b(?:large |medium |small )?eggs\b", "eggs"),
    (r"\begg\b", "eggs"),
    # -- flours (suite has no bare 'flour' alias; all-purpose is the key) --
    (r"\bwholemeal (?:self[- ]raising )?flour\b", "all-purpose flour"),
    (r"\bwholewheat flour\b", "all-purpose flour"),
    (r"\bself[- ]raising flour\b", "all-purpose flour"),
    (r"\bplain flour\b", "all-purpose flour"),
    (r"\bstrong (?:white )?bread flour\b", "all-purpose flour"),
    # gram/chickpea flour is gluten-free - NEVER the wheat-flour rule
    (r"\b(?:gram|besan|chick ?peas?) flour\b", "gram flour"),
    (r"\bflour\b", "all-purpose flour"),
    # -- meats --
    (r"\bminced (?:extra[- ]lean )?beef\b", "ground beef"),
    (r"\bextra[- ]lean minced beef\b", "ground beef"),
    (r"\bground beef\b", "ground beef"),
    (r"\bminced (?:pork|lamb)\b", "ground pork"),
    (r"\bground (?:pork|lamb)\b", "ground pork"),
    (r"\bskinless boneless chicken breasts?\b", "chicken breast"),
    (r"\bboneless skinless chicken breasts?\b", "chicken breast"),
    (r"\bskinless boneless chicken thighs?\b", "chicken thighs"),
    (r"\bboneless skinless chicken thighs?\b", "chicken thighs"),
    (r"\bchicken breasts?\b", "chicken breast"),
    (r"\bchicken thighs?\b", "chicken thighs"),
    (r"\bcooked chicken\b", "chicken breast"),
    # -- cheese (cheddar et al are alias keys) --
    (r"\breduced[- ]fat cheddar\b", "cheddar"),
    (r"\bcheddar(?: cheese)?\b", "cheddar"),
    (r"\bmozzarella\b", "mozzarella"),
    (r"\bparmesan\b", "parmesan"),
    (r"\bfeta\b", "feta"),
    (r"\bhalloumi\b", "halloumi"),
    (r"\bcream cheese\b", "cream cheese"),
    # -- pulses --
    (r"\bred lentils?\b", "red lentils"),
    (r"\bgreen(?: or brown)? lentils?\b", "lentils"),
    (r"\b(?:green|brown)? ?lentils?\b", "lentils"),
    (r"\bchick ?peas?\b", "chickpeas"),
    (r"\bkidney beans?\b", "kidney beans"),
    (r"\bblack ?beans?\b", "black beans"),
    (r"\bcannellini beans?\b", "white beans"),
    (r"\bbutter ?beans?\b", "white beans"),
    (r"\bharicot(?: verti)?s? beans?\b", "white beans"),
    (r"\bharicot beans?\b", "white beans"),
    (r"\bbaked beans\b", "white beans"),
    (r"\bgreen beans?\b", "green beans"),
    # -- peppers/onions: alias keys are PLURAL and must not double-fire --
    (r"\bbell peppers?\b", "bell peppers"),
    (r"\b(?:red|green|yellow|orange) peppers?\b", "bell peppers"),
    (r"(?<!bell )\bpeppers?\b", "bell peppers"),
    (r"\bblack pepper(?:corn)?s?\b", "black pepper"),
    (r"\bcourgette(s)?\b", "zucchini"),
    (r"\baubergine(s)?\b", "eggplant"),
    (r"\bsweetcorn\b", "corn"),
    (r"\bgin?ger\b", "ginger"),
    (r"\bgarlic cloves?\b", "garlic"),
    (r"\bgarlic\b", "garlic"),
    (r"\bred onions?\b", "red onion"),
    (r"\bspring onions?\b", "green onions"),
    (r"\bscallions?\b", "green onions"),
    (r"\bonions?\b", "onion"),
    (r"\bmange ?touts?\b", "sugar snap peas"),
    (r"\bmangetout\b", "sugar snap peas"),
    # -- seafood --
    (r"\bking prawns?\b", "shrimp"),
    (r"\bprawns?\b", "shrimp"),
    (r"\bshrimps?\b", "shrimp"),
    (r"\bsalmon (?:fillet|portions?)s?\b", "salmon fillets"),
    (r"\bcod (?:fillet|loin|portions?)s?\b", "cod fillets"),
    (r"\bhaddock (?:fillet|portions?)s?\b", "cod fillets"),
    # -- breads/grains --
    (r"\bwholemeal (?:pitta|pita) bread\b", "pita"),
    (r"\bpitta bread\b", "pita"),
    (r"\bwholemeal (?:bread|roll|bap|wrap|tortilla)s?\b", "bread"),
    (r"\bwholemeal (?:bagels?|bun)s?\b", "bread"),
    (r"\bbagels?\b", "bread"),
    (r"\bbread\b", "bread"),
    (r"\bbreadcrumbs\b", "breadcrumbs"),
    (r"\bnew potatoes?\b", "potatoes"),
    (r"\bbaking potato(?:es)?\b", "potatoes"),
    (r"\bsweet potato(?:es)?\b", "sweet potatoes"),
    (r"\bpotato(?:es)?\b", "potatoes"),
    (r"\bmushrooms?\b", "mushrooms"),
    (r"\bchopped tomatoes\b", "canned tomatoes"),
    (r"\btinned tomatoes\b", "canned tomatoes"),
    (r"\bpassata\b", "tomato passata"),
    (r"\btomato(?:es)?\b", "tomatoes"),
    (r"\bspinach\b", "spinach"),
    (r"\brolled oats?\b", "rolled oats"),
    (r"\bporridge oats?\b", "rolled oats"),
    (r"\bbasmati rice\b", "white rice"),
    (r"\blong[- ]grain rice\b", "white rice"),
    (r"\bcooked (?:basmati )?rice\b", "cooked rice"),
    (r"\bwhite rice\b", "white rice"),
    (r"\bbrown rice\b", "brown rice"),
    (r"\brice\b", "white rice"),
    # -- spices/herbs (only where the suite models them) --
    (r"\bcumin seeds?\b", "cumin seeds"),
    (r"\bground cumin\b", "cumin"),
    (r"\bcumin powder\b", "cumin"),
    (r"\bcumin\b", "cumin"),
    (r"\bgaram masala\b", "garam masala"),
    (r"\bground turmeric\b", "turmeric"),
    (r"\bturmeric powder\b", "turmeric"),
    (r"\bturmeric\b", "turmeric"),
    (r"\bsmoked paprika\b", "smoked paprika"),
    (r"\bpaprika\b", "smoked paprika"),
    (r"\bchill?i powder\b", "chili flakes"),
    (r"\bchill?i flakes\b", "chili flakes"),
    (r"\bground cinnamon\b", "cinnamon"),
    (r"\bcinnamon\b", "cinnamon"),
    (r"\bdried oregano\b", "oregano"),
    (r"\boregano\b", "oregano"),
    (r"\bdried thyme\b", "thyme"),
    (r"\bthyme\b", "thyme"),
    (r"\bfresh coriander\b", "cilantro"),
    (r"\bcoriander\b", "cilantro"),
    (r"\bdried basil\b", "basil"),
    (r"\bbasil\b", "basil"),
    (r"\bmint\b", "mint"),
    (r"\bparsley\b", "parsley"),
    (r"\brosemary\b", "rosemary"),
    (r"\bdill\b", "dill"),
    (r"\bbay leaf\b", "bay leaf"),
    (r"\bbay leaves\b", "bay leaves"),
    # -- fats/oils/sauces --
    (r"\bolive oil\b", "olive oil"),
    (r"\bvegetable oil\b", "vegetable oil"),
    (r"\bsunflower oil\b", "vegetable oil"),
    (r"\bgroundnut oil\b", "vegetable oil"),
    (r"\brape ?seed oil\b", "vegetable oil"),
    (r"\bcanola oil\b", "vegetable oil"),
    (r"\bsesame oil\b", "sesame oil"),
    (r"\bbutter\b", "butter"),
    (r"\bhoney\b", "honey"),
    (r"\bmaple syrup\b", "maple syrup"),
    (r"\bbrown sugar\b", "brown sugar"),
    (r"\bdemerara sugar\b", "brown sugar"),
    (r"\bcaster sugar\b", "sugar"),
    (r"\bgranulated sugar\b", "sugar"),
    (r"\bic(?:ing)? sugar\b", "sugar"),
    (r"\bsugar\b", "sugar"),
    (r"\bsoy ?a? ?sauce\b", "soy sauce"),
    (r"\bfish sauce\b", "fish sauce"),
    (r"\brice (?:wine )?vinegar\b", "rice vinegar"),
    (r"\bred (?:or white )?wine vinegar\b", "red wine vinegar"),
    (r"\bwhite wine vinegar\b", "red wine vinegar"),
    (r"\bbalsamic vinegar\b", "red wine vinegar"),
    (r"\btahini\b", "tahini"),
    (r"\bpeanut butter\b", "peanut butter"),
    (r"\bcoconut milk\b", "coconut milk"),
    (r"\bcoconut oil\b", "coconut oil"),
    (r"\bvegetable (?:stock|bouillon)\b", "vegetable stock"),
    (r"\bchicken (?:stock|broth)\b", "chicken stock"),
    (r"\bbeef (?:stock|broth)\b", "beef stock"),
    (r"\bsoy ?beans?\b", "soy sauce"),
    # -- leavening/thickening --
    (r"\bbaking powder\b", "baking powder"),
    (r"\bbicarbonate of soda\b", "baking soda"),
    (r"\bcorn?flour\b", "cornstarch"),
    (r"\bcorn?starch\b", "cornstarch"),
    (r"\bcocoa(?: powder)?\b", "cocoa powder"),
    (r"\bdark chocolate\b", "dark chocolate"),
    (r"\bmilk chocolate\b", "milk chocolate"),
    (r"\bchocolate(?: chips|bar)?\b", "dark chocolate"),
    (r"\btomato puree\b", "tomato puree"),
    (r"\btomato(?:e?s)?\s+pur[eé]e\b", "tomato puree"),
    (r"\btomato paste\b", "tomato puree"),
    (r"\boil\b", "vegetable oil"),
    # -- produce --
    (r"\bbanana(s)?\b", "banana"),
    (r"\blemon\b", "lemon"),
    (r"\blime\b", "lime"),
    (r"\bavocado(s)?\b", "avocado"),
    (r"\bcucumber(s)?\b", "cucumber"),
    (r"\bcarrot(s)?\b", "carrots"),
    (r"\bleek(s)?\b", "leek"),
    (r"\bceler(?:y)?\b", "celery"),
    (r"\bfrozen peas\b", "peas"),
    (r"\bgarden peas\b", "peas"),
    (r"\bpeas\b", "peas"),
    (r"\bwhole ?meal (?:pasta|spaghetti|penne|fusilli)\b", "pasta"),
    (r"\bdried (?:spaghetti|penne|fusilli|macaroni|tagliatelle)\b", "pasta"),
    (r"\bspaghetti\b", "pasta"),
    (r"\bmacaroni\b", "pasta"),
    (r"\bpenne\b", "pasta"),
    (r"\bfusilli\b", "pasta"),
    (r"\brigatoni\b", "pasta"),
    (r"\bpasta\b", "pasta"),
    (r"\bwhole ?meal noodles\b", "wheat noodles"),
    (r"\bnoodles\b", "wheat noodles"),
    (r"\brice noodles\b", "rice noodles"),
    (r"\bcouscous\b", "couscous"),
    (r"\bquinoa\b", "quinoa"),
    (r"\btofu\b", "tofu"),
    (r"\bcalif?lower\b", "cauliflower"),
    (r"\bbroccoli\b", "broccoli"),
    (r"\bkale\b", "kale"),
    (r"\bcabbage\b", "cabbage"),
    (r"\bbeet(?:root)?\b", "beetroot"),
    (r"\braspberr(?:y|ies)\b", "raspberries"),
    (r"\bstrawberr(?:y|ies)\b", "strawberries"),
    (r"\bblueberr(?:y|ies)\b", "blueberries"),
    (r"\bapple(s)?\b", "apple"),
    (r"\bpear(s)?\b", "pear"),
    # -- nuts & seeds (allergen-critical: map every suite-modeled one) --
    (r"\bflaked almonds\b", "almonds"),
    (r"\balmonds?\b", "almonds"),
    (r"\bcashew nuts?\b", "cashews"),
    (r"\bcashews?\b", "cashews"),
    (r"\bwalnuts?\b", "walnuts"),
    (r"\broasted peanuts\b", "peanuts"),
    (r"\bunsalted peanuts\b", "peanuts"),
    (r"\bpeanuts?\b", "peanuts"),
    (r"\bground ?nuts\b", "peanuts"),
    (r"\bsesame seeds?\b", "sesame seeds"),
    (r"\bchia seeds?\b", "chia seeds"),
    (r"\bsunflower seeds?\b", "sunflower seeds"),
    (r"\bpumpkin seeds?\b", "pumpkin seeds"),
    (r"\bmixed (?:nuts|seeds)\b", "mixed nuts"),
]

# Name fragments that mean a DIFFERENT food than any rule above -> never map.
NON_MAPPING = ("mixed spice", "five spice", "spice mix", "curry powder",
               "curry paste", "mustard", "mayonnaise", "ketchup", "marmite",
               "yeast", "vanilla", "nutmeg", "cloves", "cardamom",
               "all-purpose seasoning", "seasoning")


def normalize_name(raw: str) -> str:
    """Single-pass canonicalization: longest rule wins, no re-firing.

    Sequential re.sub double-fires (green peas -> green green peas), so all
    patterns are compiled into one alternation and replaced in one pass.
    """
    name = raw.strip().lower()
    name = unicodedata.normalize("NFKD", name)
    name = name.replace("\u2044", "/")  # unicode fraction slash -> ASCII
    if not hasattr(normalize_name, "_rx"):
        pats = sorted({p for p, _ in NAME_RULES}, key=len, reverse=True)
        normalize_name._rx = re.compile("|".join(f"(?:{p})" for p in pats), re.I)
        normalize_name._by_pat = {p: repl for p, repl in NAME_RULES}
    rx = normalize_name._rx

    def _sub(m: re.Match[str]) -> str:
        matched = m.group(0)
        for p, repl in normalize_name._by_pat.items():
            if re.fullmatch(p, matched, re.I):
                return repl
        return matched

    name = rx.sub(_sub, name)
    name = re.sub(r"\s+", " ", name).strip(" ,.")
    return name


# qualifier words that decorate an ingredient but are not the food itself;
# stripped only for conversion-ref lookup, never from the corpus name.
QUALIFIER_WORDS = re.compile(
    r"^(?:or\s+|\d+%[- ]fat|\d+%[- ]fat|unsweetened|sweetened|reduced[- ]fat|reduced[- ]calorie|low[- ]fat|zero[- ]fat|"
    r"fat[- ]free|extra[- ]lean|lean|fresh|frozen|dried|ground|crushed|chopped|sliced|cooked|"
    r"raw|whole|wholemeal|skinless|boneless|ripe|large|medium|small|red|green|black|white|"
    r"pitted|prepared|grated|peeled|washed|trimmed|cubed|diced|minced|drained|tinned|smoked|"
    r"desiccated|golden|plain|hot|mild|baby|free[- ]range|organic|uncooked|shop[- ]bought|"
    r"reduced[- ]salt|thawed|defrosted|finely|roughly|freshly|british|sharp|mature|mild|"
    r"greek[- ]style)\b\s*",
    re.I)


def ref_grams(ref: str, value: float) -> float:
    """SCHEMA.md's optional resolved-grams field: the table's own rate x value."""
    entry = CONVERSION_TABLE.get(ref)
    if not entry:
        raise ValueError(f"conversion ref {ref!r} missing from the suite table")
    return round(value * float(entry["grams_per_unit"]), 1)


def lookup_name(canonical: str) -> str:
    """Qualifier-stripped variant used only for ref-table lookups."""
    s = canonical
    while True:
        s2 = QUALIFIER_WORDS.sub("", s, count=1)
        if s2 == s:
            return s.strip()
        s = s2


# the individual qualifier words, for the comma-merge head check
_QUALIFIER_SET = {w for w in re.findall(r"[a-z%0-9-]+", QUALIFIER_WORDS.pattern)
                  if not w.startswith("?") and w not in ("-",)}


def display_canonical(name: str) -> str:
    """Alias-recognizable display name: prefer the qualifier-stripped form.

    rs.py matches allergen aliases EXACTLY on the stored name, so a stored
    'low-fat greek-style yogurt' would silently drop the dairy class; the
    stripped canonical keeps classes correct. Longer stripped forms win.
    """
    stripped = lookup_name(name).strip(" -")
    return stripped if stripped else name


# ---------------------------------------------------------------------------
# quantity parsing
# ---------------------------------------------------------------------------
NUM_WORDS = {"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
             "five": 5, "six": 6, "eight": 8, "half": 0.5}
SIZE_WORDS = re.compile(r"\b(small|medium|large)\b", re.I)

# piece refs: (regex on normalized line, conversion_ref, ref's size word)
PIECE_REFS: list[tuple[re.Pattern[str], str, str | None]] = [
    (re.compile(r"\b(?:garlic )?cloves?\b"), "garlic_clove", None),
    (re.compile(r"\b(?:large|medium|small)?\s*eggs?(?![a-z])\b"), "egg_piece", None),
    (re.compile(r"\bonions?\b"), "onion_piece", "medium"),
    (re.compile(r"\bcarrots?\b"), "carrot_piece", "medium"),
    (re.compile(r"\bpotatoes\b"), "potato_piece", "medium"),
    (re.compile(r"\bsweet potatoes\b"), "sweet_potato_piece", "medium"),
    (re.compile(r"\bbell peppers?\b"), "bell_pepper_piece", "medium"),
    (re.compile(r"\btomatoes\b"), "tomato_piece", "medium"),
    (re.compile(r"\bcucumbers?\b"), "cucumber_piece", "medium"),
    (re.compile(r"\bavocados?\b"), "avocado_piece", "medium"),
    (re.compile(r"\bzucchini\b"), "zucchini_piece", "medium"),
    (re.compile(r"\beggplant\b"), "eggplant_piece", "medium"),
    (re.compile(r"\blemons?\b"), "lemon_piece", None),
    (re.compile(r"\blimes?\b"), "lime_piece", None),
    (re.compile(r"\bchicken breasts?\b"), "chicken_breast_piece", None),
    (re.compile(r"\bchicken thighs?\b"), "chicken_thigh_piece", None),
    (re.compile(r"\bsalmon fillets\b"), "salmon_fillet", None),
    (re.compile(r"\bcod fillets\b"), "cod_fillet", None),
    (re.compile(r"\bpork chops?\b"), "pork_chop_piece", None),
    (re.compile(r"\bshrimp\b"), "shrimp_piece", None),
    (re.compile(r"\btortillas?\b"), "tortilla_piece", None),
    (re.compile(r"\bpita\b"), "pita_piece", None),
    (re.compile(r"\bbread slices?\b"), "bread_slice", None),
    (re.compile(r"\bhalloumi slices?\b"), "halloumi_slice", None),
    (re.compile(r"\btofu blocks?\b"), "tofu_block", None),
    (re.compile(r"\bcauliflower heads?\b"), "cauliflower_head", None),
    (re.compile(r"\bmushroom caps?\b"), "mushroom_piece", None),
]

# ingredient display-name -> conversions.json ref base (underscored).
# Ref existence is verified at runtime against the suite table: a household
# ref is emitted ONLY if f"{base}_{suffix}" exists in conversions.json.
SPOON_REF_BY_NAME: dict[str, str] = {
    "olive oil": "olive_oil", "vegetable oil": "vegetable_oil",
    "sesame oil": "sesame_oil", "butter": "butter", "milk": "milk",
    "greek yogurt": "greek_yogurt", "yogurt": "greek_yogurt",
    "sugar": "sugar", "brown sugar": "brown_sugar",
    "all-purpose flour": "flour",
    "honey": "honey", "maple syrup": "maple_syrup",
    "soy sauce": "soy_sauce", "fish sauce": "fish_sauce",
    "rice vinegar": "rice_vinegar", "red wine vinegar": "red_wine_vinegar",
    "tahini": "tahini", "peanut butter": "peanut_butter",
    "coconut milk": "coconut_milk", "chicken stock": "chicken_stock",
    "vegetable stock": "veg_stock",
    "cumin": "cumin", "cumin seeds": "cumin_seeds", "turmeric": "turmeric",
    "smoked paprika": "smoked_paprika", "paprika": "smoked_paprika",
    "garam masala": "garam_masala", "oregano": "oregano", "thyme": "thyme",
    "basil": "basil", "mint": "mint", "parsley": "parsley",
    "cilantro": "cilantro", "chili flakes": "chili_flakes",
    "black pepper": "black_pepper", "salt": "salt", "cornstarch": "cornstarch",
    "baking powder": "baking_powder", "parmesan": "parmesan",
    "cheddar": "cheddar", "cinnamon": "cinnamon",
    "tomato puree": "tomato_puree", "sesame seeds": "sesame_seeds",
    "black beans": "black_beans", "kidney beans": "kidney_beans",
    "chickpeas": "chickpeas", "white beans": "white_beans",
    "lentils": "cooked_lentils", "red lentils": "dry_lentils",
    "peas": "peas", "corn": "corn",
    "spinach": "spinach", "kale": "kale", "cabbage": "cabbage",
    "broccoli": "broccoli", "cauliflower": "cauliflower",
    "mushrooms": "mushrooms", "cucumber": "cucumber", "canned tomatoes": "canned_tomatoes",
    "peanuts": "peanuts", "almonds": "almonds", "cashews": "cashews",
    "rolled oats": "rolled_oats", "quinoa": "dry_quinoa",
    "couscous": "dry_couscous", "pasta": "pasta",
    "cooked rice": "cooked_rice", "white rice": "dry_rice",
}

# Suite conversions.json contents, loaded in main(); empty until loaded.
CONVERSION_REFS: set[str] = set()
CONVERSION_TABLE: dict[str, Any] = {}


def ref_exists(ref: str) -> bool:
    return ref in CONVERSION_REFS

UNRESOLVABLE_UNITS = re.compile(
    r"\b(handfuls?|splash(es)?|dash(es)?|drizzle|sprigs?|pinch(es)?|stalks?|"
    r"thumb[- ]sized|knob(?:s)? of|sheets?|sachets?|tins?|cans?|packs?|"
    r"bunch(?:es)?|sticks?|slices? of|wedges?|squares?|strips?)\b", re.I)


def parse_quantity(line: str) -> dict[str, Any] | None:
    """Return {name, qty} with qty resolving against the suite tables, or None.

    The returned qty is one of:
      {"kind": "source_grams", "grams": N}   - NHS states the mass
      {"kind": "household", "ref": K, "qty": n, "grams": N}
      {"kind": "unknown"}                    - honestly unresolved
    """
    text = unicodedata.normalize("NFKD", line).strip()
    text = re.sub(r"\s+", " ", text)
    if not text:
        return None

    # split leading quantity phrase from the ingredient name
    m_num = re.match(
        r"^(?P<lead>(?P<qty>\d+(?:\.\d+)?|\d+\s*x\s*\d+|\d+/\d+|one|two|three|four|five|six|"
        r"eight|half(?:\s+an?)?|a|an))\s+(?P<rest>.+)$", text, re.I)
    qty_val: float | None = None
    rest = text
    if m_num:
        lead = m_num.group("lead").lower()
        rest = m_num.group("rest")
        xm = re.match(r"^(\d+)\s*x\s*(\d+)$", lead)
        if xm:
            qty_val = float(xm.group(1))  # count of the stated-size unit
        elif lead in NUM_WORDS:
            qty_val = NUM_WORDS[lead]
        elif "/" in lead:
            a, b = lead.split("/")
            qty_val = float(a) / float(b)
        else:
            try:
                qty_val = float(lead)
            except ValueError:
                qty_val = None
        # "half a teaspoon" / "half a lemon" style: half + a + unit
        if lead.startswith("half") and qty_val is None:
            qty_val = 0.5

    def name_of(s: str) -> str:
        # drop prep notes after a comma, trailing parentheticals, "to serve"
        head = s.split(",")[0]
        head = re.sub(r"^(?:of\s+)", "", head.strip(), flags=re.I)
        head = re.sub(r"\s*\([^)]*\)\s*$", "", head.strip(), flags=re.I)
        head = re.sub(r"\s+to serve\s*$", "", head.strip(), flags=re.I)
        return head.strip()

    grams_stated: float | None = None

    # grams stated at the head of the line ("150g X", "2 x 400g tins of X"):
    # cnt and grams are separate groups so the multiplier never eats digits.
    mg = re.match(r"^(?:(?P<cnt>\d+)\s*x\s*)?(?P<grams>\d+(?:\.\d+)?)\s*(?:g|grams?)\b",
                  text, re.I)
    kg = re.match(r"^(?:(?P<cnt>\d+)\s*x\s*)?(?P<grams>\d+(?:\.\d+)?)\s*kg\b", text, re.I)
    # per-piece grams stated later in the line ("4 potatoes (about 225g each)")
    mg_each = (re.search(r"(?P<grams>\d+(?:\.\d+)?)\s*(?:g|grams?)\b\s*each\b", text, re.I)
               if not mg and not kg else None)
    # tight parenthetical grams without "each": "1 can (about 210g) red kidney beans"
    mg_paren = (re.search(r"\(\s*(?:about\s+|approx\.?\s+)?(?P<grams>\d+(?:\.\d+)?)\s*"
                          r"(?:g|grams?)\s*\)", text, re.I)
                if not mg and not kg and not mg_each else None)

    # ml: present in the line -> unresolvable (never ml-as-grams)
    has_ml = re.search(r"\d+(?:\.\d+)?\s*(?:ml|millilit|litre|liter|l)\b", text, re.I)

    raw_name_part = name_of(rest)

    if kg:
        grams_stated = float(kg.group("grams")) * 1000.0
        if kg.group("cnt"):
            grams_stated *= float(kg.group("cnt"))
    elif mg and not has_ml:
        grams_stated = float(mg.group("grams"))
        if mg.group("cnt"):
            grams_stated *= float(mg.group("cnt"))
    elif mg_each and not has_ml and qty_val is not None:
        grams_stated = float(mg_each.group("grams")) * qty_val
    elif mg_paren and not has_ml:
        grams_stated = float(mg_paren.group("grams")) * (qty_val or 1.0)

    if grams_stated is not None and grams_stated > 0 and not has_ml:
        stripped = re.sub(r"^\d+\s*x\s*", "", rest)
        stripped = re.sub(r"^(?:\d+\s*x\s*)?(?:\d+(?:\.\d+)?\s*(?:g|grams?|kg)\s*)",
                          "", stripped, flags=re.I)
        stripped = re.sub(r"\([^)]*\d+(?:\.\d+)?\s*(?:g|grams?|kg)[^)]*\)", " ", stripped,
                          flags=re.I)  # drop the stated-grams parenthetical from the name
        name = normalize_name(name_of(stripped))
        # UK style splits one ingredient across a comma ("boneless, skinless
        # chicken breasts"): if the head is only a qualifier word, use the
        # comma-merged name so the stored name stays alias-recognizable.
        if "," in rest and name and all(
                w in _QUALIFIER_SET for w in name.split()):
            merged = normalize_name(name_of(re.sub(r"\s*,\s*", " ", stripped)))
            if merged:
                name = merged
        if not name:
            return None
        return {"name": display_canonical(name), "qty": {"kind": "source_grams", "grams": grams_stated}}

    if has_ml:
        return {"name": display_canonical(normalize_name(raw_name_part)), "qty": {"kind": "unknown"}}

    if UNRESOLVABLE_UNITS.search(text):
        return {"name": display_canonical(normalize_name(raw_name_part)), "qty": {"kind": "unknown"}}

    # spoon measures ("2 tbsp", "1 heaped teaspoon", "half a tablespoon")
    ms = re.match(r"^(?P<qty>\d+(?:\.\d+)?|half(?:\s+an?)?|a|an|one|two|three)\s+"
                  r"(?:(?:heaped|level|rounded|scant)\s+)?"
                  r"(?P<unit>tablespoons?|tbsp|teaspoons?|tsp|dessertspoons?)\s+"
                  r"(?:of\s+)?(?P<name>.+)$", text, re.I)
    if ms:
        q = ms.group("qty").lower()
        n = NUM_WORDS.get(q)
        if n is None:
            n = 0.5 if q.startswith("half") else float(q)
        if ms.group("unit").lower().startswith("dessert"):
            return {"name": display_canonical(normalize_name(ms.group("name"))),
                    "qty": {"kind": "unknown"}}
        name = normalize_name(name_of(ms.group("name")))
        base = SPOON_REF_BY_NAME.get(name) or SPOON_REF_BY_NAME.get(lookup_name(name))
        if base:
            unit_l = ms.group("unit").lower()
            suffix = "tbsp" if unit_l.startswith(("table", "tabs", "tbs")) else "tsp"
            ref = f"{base}_{suffix}"
            if ref_exists(ref):
                return {"name": display_canonical(name),
                        "qty": {"kind": "household", "value": n, "unit": suffix,
                                "conversion_ref": ref, "grams": ref_grams(ref, n)}}
        return {"name": display_canonical(name), "qty": {"kind": "unknown"}}

    # cup measures
    mc = re.match(r"^(?P<qty>\d+(?:\.\d+)?|half(?:\s+an?)?|a|an|one|two)\s+"
                  r"(?:cup|cups)\s+(?:of\s+)?(?P<name>.+)$", text, re.I)
    if mc:
        q = mc.group("qty").lower()
        n = NUM_WORDS.get(q)
        if n is None:
            n = 0.5 if q.startswith("half") else float(q)
        name = normalize_name(name_of(mc.group("name")))
        base = SPOON_REF_BY_NAME.get(name) or SPOON_REF_BY_NAME.get(lookup_name(name))
        if base:
            ref = f"{base}_cup"
            if ref_exists(ref):
                return {"name": display_canonical(name),
                        "qty": {"kind": "household", "value": n, "unit": "cup",
                                "conversion_ref": ref, "grams": ref_grams(ref, n)}}
        return {"name": display_canonical(name), "qty": {"kind": "unknown"}}

    # piece counts: "2 large eggs", "1 medium onion", "1 onion", "6 garlic cloves"
    if qty_val is not None:
        name_raw = name_of(rest)
        name_norm = normalize_name(name_raw)
        name_look = lookup_name(name_norm)
        size = SIZE_WORDS.search(name_raw)
        # guards: a different food shares the piece keyword (spring onion is
        # not a 110g onion; a cherry tomato is not a 123g tomato)
        look_text = f"{name_raw.lower()} {name_look}"
        if re.search(r"\b(?:green|spring) onions?\b|\bscallions?\b", look_text):
            return {"name": display_canonical(name_norm), "qty": {"kind": "unknown"}}
        if re.search(r"\b(?:cherry|grape) tomatoes?\b", look_text):
            return {"name": display_canonical(name_norm), "qty": {"kind": "unknown"}}
        for rx, ref, ref_size in PIECE_REFS:
            if not ref_exists(ref):
                continue
            if (rx.search(name_raw.lower()) or rx.search(name_norm)
                    or rx.search(name_look)):
                if size and ref_size and size.group(1).lower() != ref_size:
                    break  # stated size contradicts the ref's canonical size
                return {"name": display_canonical(name_norm),
                        "qty": {"kind": "household", "ref": ref, "qty": qty_val}}
        return {"name": display_canonical(name_norm), "qty": {"kind": "unknown"}}

    return {"name": display_canonical(normalize_name(raw_name_part)),
            "qty": {"kind": "unknown"}}


# ---------------------------------------------------------------------------
# steps: split, rephrase doneness, attach safety
# ---------------------------------------------------------------------------
# Doneness clauses in NHS method text, and the foods each one is about. The
# endpoint comes from the recipe's own ingredients through food_safety (turkey
# mince is ground poultry, 165 F; pork loin is a whole cut, 145 F plus rest),
# never from the clause: the old table gave every "no longer pink" 160 F,
# including ground poultry, and gave pork no rest.
DONENESS_CLAUSES: list[tuple[re.Pattern[str], re.Pattern[str]]] = [
    (re.compile(r"until the (?:chicken|turkey)(?: juices run clear| is (?:white and )?"
                r"(?:cooked through|no longer pink))", re.I),
     re.compile(r"\b(?:chicken|turkey)\b")),
    (re.compile(r"until (?:the )?(?:fish|salmon|cod|haddock) (?:is cooked through|"
                r"flakes? (?:easily )?(?:with a fork|apart))", re.I),
     re.compile(r"\b(?:fish|salmon|cod|haddock|pollock|trout|mackerel)\b")),
    (re.compile(r"until the (?:eggs?|egg whites?) (?:are|is) (?:just )?set\b", re.I),
     re.compile(r"\beggs?\b")),
    (re.compile(r"until the saus?ages? are (?:browned and )?(?:cooked through|no longer pink)",
                re.I),
     re.compile(r"\bsausages?\b")),
    (re.compile(r"until (?:the )?(?:pork|bacon|ham) is cooked through", re.I),
     re.compile(r"\b(?:pork|bacon|ham|gammon)\b")),
    # generic: any meat in the recipe
    (re.compile(r"until (?:the meat is )?no longer pink(?: in the (?:middle|centre))?", re.I),
     re.compile(r".")),
]
_REHEAT_SOURCE = re.compile(r"\bre-?heat|\bre-?warm|\bpiping hot\b|\bheat(?:s|ing)? "
                            r"(?:it |them )?through\b", re.I)


def _endpoint(classes: set[str]) -> tuple[str, int]:
    """The strictest (class, temp) among classes; whole cuts lose ties."""
    ranked = sorted(classes, key=lambda c: (food_safety.MIN_F[c], c not in food_safety.REST_MIN))
    cls = ranked[-1]
    return cls, food_safety.MIN_F[cls]


def _check_clause(cls: str, temp: int, where: str = "in the thickest part") -> str:
    c = C_FOR_F[temp]
    rest = (f", then rest it for at least {food_safety.REST_MIN[cls]} minutes"
            if cls in food_safety.REST_MIN else "")
    return f"until a food thermometer {where} reads {temp} °F ({c} °C){rest}"


def _safety(cls: str, temp: int) -> dict[str, Any]:
    return {"class": cls, "temp_f": temp, "method": "thermometer", "source": FSIS_SOURCE}


def build_steps(method_items: list[str], ingredient_names: list[str], title: str
                ) -> tuple[list[dict[str, Any]], list[str]]:
    """(steps, safety problems). Problems non-empty means the page is skipped.

    Each doneness clause becomes a thermometer check at the strictest
    endpoint of the foods it covers; each reheating step carries its own
    165 F leftovers check, whatever was checked before it; any required food
    still unchecked gets one closing check that names it, at the strictest
    endpoint of what is left (165 F for a casserole). The result must pass
    food_safety.safety_violations.
    """
    ing_classes = {n: food_safety.ingredient_class(n) for n in ingredient_names}
    meat = {c for c in ing_classes.values()
            if c and c not in ("egg", "flesh_fish", "flesh_shellfish", "leftovers")}
    steps: list[dict[str, Any]] = []
    for raw in method_items:
        text = re.sub(r"\s+", " ", raw).strip()
        text = re.sub(r"^Information:.*$", "", text).strip()
        if not text:
            continue
        step: dict[str, Any] = {"text": text}
        tm = re.search(r"(\d+(?:\.\d+)?)(?:\s*-\s*(\d+(?:\.\d+)?))?\s*"
                       r"(minutes?|mins?|secs?|seconds?)\b", text, re.I)
        if tm:
            val = float(tm.group(2) or tm.group(1))
            if tm.group(3).lower().startswith("s"):
                val /= 60.0
            if 0 < val <= 240:
                step["timer_min"] = val
        if _REHEAT_SOURCE.search(text):
            # reheating overrides the product class
            step["reheat"] = True
            step["safety"] = _safety("leftovers", 165)
            if "thermometer" not in text.lower():
                step["text"] = (f"{text.rstrip('.')}. Check with a food thermometer: it must "
                                f"read 165 °F ({C_FOR_F[165]} °C).")
        else:
            for clause, foods in DONENESS_CLAUSES:
                m = clause.search(text)
                if not m:
                    continue
                classes = {c for n, c in ing_classes.items() if c and foods.search(n.lower())}
                if foods.pattern == ".":
                    classes = set(meat)
                if not classes:
                    continue  # the clause names a food this recipe does not list
                cls, temp = _endpoint(classes)
                if food_safety.is_mixed_dish(title):
                    cls, temp = "leftovers", 165  # the casserole endpoint
                    where = "in the centre"
                else:
                    where = "in the thickest part"
                step["text"] = text[:m.start()] + _check_clause(cls, temp, where) + text[m.end():]
                step["safety"] = _safety(cls, temp)
                break
        steps.append(step)

    stub = {"id": "nhs-page", "title": title, "steps": steps,
            "ingredients": [{"name": n} for n in ingredient_names]}
    uncovered = set(food_safety.uncovered_classes(stub))
    # the closing check is about cooking the dish, so it goes before any
    # step that reheats leftovers
    if uncovered:
        cls, temp = _endpoint(uncovered)
        if "leftovers" in uncovered:
            cls, temp = "leftovers", 165
        # one word per food: "chicken breast" is "chicken"
        words = sorted({food_safety.food_words(n)[0] for n, c in ing_classes.items()
                        if c in uncovered and food_safety.food_words(n)})
        foods = " and ".join(words) if words else "dish"
        check_step = {"text": f"Before serving, cook the {foods} "
                              f"{_check_clause(cls, temp, 'in the centre of the thickest piece')}.",
                      "safety": _safety(cls, temp)}
        at = next((i for i, s in enumerate(steps) if s.get("reheat")), len(steps))
        steps.insert(at, check_step)
    problems = food_safety.safety_violations(stub)
    return steps, problems


# ---------------------------------------------------------------------------
# claims
# ---------------------------------------------------------------------------
CLAIM_DENYLIST: dict[str, str] = {
    "dairy-free": r"\b(cheese|milk|yog|yogh|cream|butter(?!nut| milk| squash)|paneer|custard|milk ?shake|fromage)\w*",
    "nut-free": r"\b(nut|nuts|almond|cashew|pecan|walnut|hazelnut|brazil|macadamia|pistachio|peanut)\w*",
    "gluten-free": r"\b(flour|bread|pasta|noodle|spaghetti|penne|fusilli|macaroni|tagliatelle|wrap|tortilla|pitta|pita|"
                   r"biscuit|cookie|cracker|couscous|barley|rye|semolina|dough|pastry|crumb|oat|bun|roll|toast)\w*",
    "vegetarian": r"\b(chicken|beef|pork|lamb|turkey|fish|salmon|cod|haddock|tuna|prawn|shrimp|meat|mince|sausage|"
                  r"bacon|ham|anchov|kipper|mackerel|sardine|stock|broth|gelatin|meatball|burger)\w*",
}
CLAIM_DENYLIST["vegan"] = CLAIM_DENYLIST["vegetarian"] + r"|\b(egg|dairy|cheese|milk|yog|yogh|cream|butter|honey|paneer|custard)\w*"


def decide_claims(recipe_ingredients: list[dict[str, Any]], raw_lines: list[str],
                  scanner: Any, allergens: dict[str, Any],
                  steps: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Claims the scanner verifies and the composition gate proves
    (composition.claim_problems: unknown composition blocks every claim)."""
    names = " | ".join(raw_lines).lower()
    blocked: list[tuple[str, str]] = []
    claims: list[dict[str, Any]] = []
    for claim_name in ("vegetarian", "vegan", "gluten-free", "dairy-free", "nut-free"):
        hit = re.search(CLAIM_DENYLIST[claim_name], names)
        if hit:
            blocked.append((claim_name, f"raw text mentions {hit.group(0)!r}"))
            continue
        claim = {"claim": claim_name, "evidence": {"conflicts": []}}
        verdict = scanner.verify_claim({"ingredients": recipe_ingredients}, claim)
        if verdict is not True:
            blocked.append((claim_name, f"scanner: {verdict}"))
            continue
        problems = composition.claim_problems(
            {"ingredients": recipe_ingredients, "steps": steps, "claims": [claim]}, allergens)
        if problems:
            blocked.append((claim_name, "; ".join(problems[claim_name])))
            continue
        claims.append(claim)
    return claims


# ---------------------------------------------------------------------------
# page parsing
# ---------------------------------------------------------------------------
def parse_page(path: Path) -> dict[str, Any] | None:
    html = path.read_text(encoding="utf-8")
    m = re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(1))
    except json.JSONDecodeError:
        return None
    for it in (d if isinstance(d, list) else [d]):
        t = it.get("@type", "")
        if (isinstance(t, str) and "Recipe" in t) or (
                isinstance(t, list) and any("Recipe" in str(x) for x in t)):
            return it
    return None


def method_steps_from_html(html: str) -> list[str]:
    mm = re.search(r"<h2[^>]*>\s*Method\s*</h2>(.*?)</section>", html, re.S)
    if not mm:
        mm = re.search(r"Method</h2>(.{0,8000})", html, re.S)
    if not mm:
        return []
    items = []
    for li in re.findall(r"<li[^>]*>(.*?)</li>", mm.group(1), re.S):
        txt = html_unescape(re.sub(r"<[^>]+>", "", li))
        txt = re.sub(r"\s+", " ", txt).strip()
        if txt:
            items.append(txt)
    return items


def iso_minutes(v: str) -> int | None:
    m = re.fullmatch(r"PT(?:(\d+)H)?(?:(\d+)M)?", (v or "").strip())
    if not m:
        return None
    return int(m.group(1) or 0) * 60 + int(m.group(2) or 0)


def servings_from_yield(y: str) -> int | None:
    m = re.search(r"serves\s+(\d+)", (y or "").lower())
    if m:
        return int(m.group(1))
    m = re.search(r"makes\s+(\d+)", (y or "").lower())
    if m:
        return int(m.group(1))
    return None


# ---------------------------------------------------------------------------
# per-recipe judgment: cuisine + meal slots (keyword classifier, reviewed)
# ---------------------------------------------------------------------------
CUISINE_RULES: list[tuple[str, str]] = [
    (r"curry|biryani|dhal|daal|tandoori|samosa|chapatti|bhaji|masala|bengali|bombay|madras|korma|"
     r"bariis|isombe|jollof|egusi|shal?low|keema|rajma|chana|aloo|saag|paneer", "indian"),
    (r"stir[- ]fry|noodle|fried rice|teriyaki|sweet[- ]and[- ]sour|thai|vietnamese|chinese|japanese|"
     r"korean|gyoza|satay|pad ?thai|ramen|tofu scramble|egg fried|chow mein|edamame", "asian"),
    (r"pasta|risotto|lasagne|carbonara|margherita|pizza|spaghetti|penne|fusilli|gnocchi|pesto|"
     r"bruschetta|tiramisu|meatball|ragu|bolognese|italian", "italian"),
    (r"taco|burrito|quesadilla|fajita|enchilada|salsa|guacamole|tortilla|nachos|mexican|"
     r"chilli (?:con|non)|refried", "mexican"),
    (r"hummus|falafel|pitta|pita|kebab|tzatziki|greek|moroccan|tagine|couscous|spanish|paella|"
     r"tapas|mediterranean|shakshuka|frittata|caprese|bruschetta", "mediterranean"),
]
SLOT_RULES: dict[str, list[str]] = {
    "Breakfast": ["breakfast"], "Lunch": ["lunch"], "Lunchbox": ["lunch"],
    "Dinner": ["dinner"], "Snacks": ["lunch"], "Puddings": ["dinner"],
    "Drinks": ["breakfast", "lunch"], "Barbecue and picnic": ["lunch", "dinner"],
}


def judge(name: str, categories: list[str]) -> tuple[str, list[str]]:
    n = name.lower()
    cuisine = "american"
    for rx, c in CUISINE_RULES:
        if re.search(rx, n):
            cuisine = c
            break
    slots: list[str] = []
    for c in categories or []:
        for s in SLOT_RULES.get(c, []):
            if s not in slots:
                slots.append(s)
    if not slots:
        slots = ["lunch", "dinner"]
    return cuisine, slots


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--suite-dir", required=True)
    ap.add_argument("--pages", required=True, help="dir of fetched NHS recipe pages")
    ap.add_argument("--mode", choices=["measure", "write"], required=True)
    args = ap.parse_args()
    suite_dir = Path(args.suite_dir)
    sys.path.insert(0, str(suite_dir))
    import rights as rights_mod
    import rs

    conv = json.loads((suite_dir / "conversions.json").read_text())
    conv = conv.get("conversions", conv)
    CONVERSION_REFS.clear()
    CONVERSION_REFS.update(conv.keys())
    CONVERSION_TABLE.clear()
    CONVERSION_TABLE.update(conv)
    allergens = json.loads((suite_dir / "allergens.json").read_text())
    scanner = rs.AllergenScanner(allergens)
    alias_keys = {k.lower() for k in allergens["ingredient_aliases"]}

    # current corpus + manifest (seeds)
    existing = [json.loads(l) for l in CORPUS.read_text().splitlines() if l.strip()]
    manifest = json.loads(MANIFEST.read_text())
    records = manifest["records"]

    # dedupe keys already present (SCHEMA.md section 7)
    norm = lambda s: re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()
    seen_keys = {(norm(r["title"]),
                  frozenset(norm(i["name"]) for i in r["ingredients"])) for r in existing}

    pages = sorted(Path(args.pages).glob("*.html"))
    selected: list[dict[str, Any]] = []
    skipped: list[tuple[str, str, str]] = []
    next_num = 1

    for page in pages:
        slug = page.stem
        it = parse_page(page)
        if it is None:
            skipped.append((slug, it and it.get("name", "?") or "?", "no Recipe JSON-LD"))
            continue
        html = page.read_text(encoding="utf-8")
        raw_lines = [x.strip() for x in it.get("recipeIngredient", []) if x.strip()]
        if len(raw_lines) < 3:
            skipped.append((slug, it.get("name", "?"), f"only {len(raw_lines)} ingredient lines"))
            continue
        parsed = [parse_quantity(x) for x in raw_lines]
        if any(p is None for p in parsed):
            skipped.append((slug, it.get("name", "?"), "unparseable line"))
            continue
        resolved = sum(1 for p in parsed if p["qty"]["kind"] != "unknown")
        frac = resolved / len(parsed)
        if frac < MIN_RESOLVE:
            unresolved = [p["name"] for p in parsed if p["qty"]["kind"] == "unknown"]
            skipped.append((slug, it.get("name", "?"),
                            f"resolution {frac:.0%} < 95% (unresolved: {', '.join(unresolved[:4])})"))
            continue

        # household lines: the parser resolved grams via ref_grams (which
        # raises if a ref is missing from the suite table); guard anyway
        if any(p["qty"].get("kind") == "household"
               and (not p["qty"].get("conversion_ref") or not p["qty"].get("grams"))
               for p in parsed):
            skipped.append((slug, it.get("name", "?"), "household line without resolved grams"))
            continue

        minutes = iso_minutes(it.get("totalTime", ""))
        servings = servings_from_yield(it.get("recipeYield", ""))
        if not minutes or not servings:
            skipped.append((slug, it.get("name", "?"),
                            f"time/yield unparseable: {it.get('totalTime')!r}/{it.get('recipeYield')!r}"))
            continue

        categories = it.get("recipeCategory") or []
        if isinstance(categories, str):
            categories = [categories]
        cuisine, slots = judge(it.get("name", ""), categories)

        # Reheat evidence is the source's own reheating instruction, on the
        # step that gives it; storage tips are not reheating.
        title_for_safety = re.sub(r"\s+recipe$", "", it.get("name", "").strip())
        steps, safety_problems = build_steps(method_steps_from_html(html),
                                             [p["name"] for p in parsed], title_for_safety)
        if not steps:
            skipped.append((slug, it.get("name", "?"), "no method steps found in HTML"))
            continue
        if safety_problems:
            skipped.append((slug, it.get("name", "?"),
                            "food-safety conversion incomplete: " + "; ".join(safety_problems)))
            continue

        ingredients = [{"name": p["name"], "qty": p["qty"]} for p in parsed]
        unaliased = [p["name"] for p in parsed if p["name"] not in alias_keys]
        claims = decide_claims([{"name": p["name"]} for p in parsed], raw_lines, scanner,
                               allergens, steps)

        title = re.sub(r"\s+recipe$", "", it.get("name", "").strip())
        fl_id = f"fl-{ID_TAG}-{next_num:04d}"
        next_num += 1

        selected.append({
            "recipe": {
                "rs_version": "1", "id": fl_id, "title": title,
                "cuisine": cuisine, "meal_slots": slots, "minutes": minutes,
                "servings": servings, "ingredients": ingredients, "steps": steps,
                "source_ref": fl_id,
                "provenance": {
                    "source_page": f"https://www.nhs.uk/healthier-families/recipes/{slug}/",
                    "rights_terms": NHS_TERMS_URL,
                    "adaptation": ("wording adapted for structured steps and "
                                   "thermometer doneness (OGL adapted-content rule)"),
                },
            },
            "record": {
                "source_id": "nhs_website",
                "source_type": "government",
                "origin": "NHS Website Content (Department of Health and Social Care)",
                "license": "OGL-3.0",
                "access_date": BUILD_DATE,
                "license_evidence": (
                    f"quoted OGL v3.0 release at {NHS_TERMS_URL} (retrieved 2026-10-11, "
                    f"SOURCES.md section 2); per-recipe page "
                    f"https://www.nhs.uk/healthier-families/recipes/{slug}/ "
                    f"(datePublished {str(it.get('datePublished', ''))[:10]})"),
                "permissions": {"text": True, "images": False, "modification": True,
                                "attribution": True, "caching": True, "offline_use": True},
            },
            "claims_decisions": claims,
            "unaliased": sorted(set(unaliased)),
            "frac": frac,
        })

    print(f"parsed pages: {len(pages)}")
    print(f"selected (resolution >= {MIN_RESOLVE:.0%}): {len(selected)}")
    print(f"skipped: {len(skipped)}")
    for slug, name, why in skipped[:40]:
        print(f"  SKIP {slug}: {why}")

    cov: dict[str, int] = {}
    for s in selected:
        cov[s["recipe"]["cuisine"]] = cov.get(s["recipe"]["cuisine"], 0) + 1
    print(f"selected cuisines: {cov}")
    slots_cov: dict[str, int] = {}
    for s in selected:
        for sl in s["recipe"]["meal_slots"]:
            slots_cov[sl] = slots_cov.get(sl, 0) + 1
    print(f"selected slots: {slots_cov}")
    times_cov: dict[str, int] = {"0-15": 0, "16-30": 0, "31-45": 0, "46-60": 0, "61+": 0}
    for s in selected:
        m = s["recipe"]["minutes"]
        band = "0-15" if m <= 15 else "16-30" if m <= 30 else "31-45" if m <= 45 else "46-60" if m <= 60 else "61+"
        times_cov[band] += 1
    print(f"selected time bands: {times_cov}")
    n_claims = sum(len(s["claims_decisions"]) for s in selected)
    print(f"claims to write: {n_claims}")
    unalias_all = sorted({u for s in selected for u in s["unaliased"]})
    print(f"unaliased names in selected: {unalias_all}")

    if args.mode == "measure":
        print("\n(measure mode: nothing written)")
        return 0

    # dedupe against existing corpus
    added: list[dict[str, Any]] = []
    for s in selected:
        r = s["recipe"]
        key = (norm(r["title"]), frozenset(norm(i["name"]) for i in r["ingredients"]))
        if key in seen_keys:
            print(f"dedupe skip: {r['id']} {r['title']!r}")
            continue
        seen_keys.add(key)
        r["claims"] = s["claims_decisions"]
        added.append(s)

    with CORPUS.open("a", encoding="utf-8", newline="\n") as f:
        for s in added:
            f.write(json.dumps(s["recipe"], ensure_ascii=False) + "\n")
    for s in added:
        records[s["recipe"]["source_ref"]] = s["record"]
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
    print(f"\nappended {len(added)} NHS recipes; corpus now has "
          f"{len(existing) + len(added)} recipes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
