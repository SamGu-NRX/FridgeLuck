"""Food-safety gate for RS v1 recipes (SPEC 3.1, SCHEMA.md section 3).

Every corpus tool that writes or accepts a recipe calls `safety_violations`;
`validate_corpus.py` refuses the corpus when any recipe has one. The gate is
independent of suite C's linter: the pinned linter at 26c7004 accepted a
160 F casserole, a whole-cut pork check with no rest, and checks that existed
only in metadata, so the corpus cannot rely on it.

Rules come from one source, the USDA FSIS Safe Minimum Internal Temperature
Chart (FSIS_URL), fetched 2026-10-11 (page "Last Updated: Apr 14, 2025"). The
chart rows this module encodes are quoted in FSIS_ROWS.

Endpoint rules (`endpoint_violations`):

1. Classes. Each ingredient line is classified by name (`ingredient_class`):
   poultry including ground poultry 165 F; ground beef, pork, veal, lamb and
   raw sausage 160 F; whole cuts of beef, pork, veal and lamb 145 F plus a
   3-minute rest; fish and shellfish 145 F; eggs 160 F. Already-cooked poultry
   or meat is reheated, so 165 F. A title naming a casserole-type dish
   (MIXED_DISH_TITLE) adds the 165 F casserole endpoint for the finished dish.
   Ready-to-eat products (stock, fish sauce, canned fish, anchovies, buns)
   carry no doneness class of their own.
2. Coverage. Every required class is met by a thermometer check
   (`step.safety`) that names it at or above its minimum, or by a stricter
   check on a step that cooks that ingredient, or by the dish's 165 F
   casserole check.
3. Strictest endpoint. Foods cooked or mixed together reach the highest of
   their minimums. A check whose step text names foods of several classes
   must reach the highest; and when a step without a check mixes foods of
   several classes (raw egg folded into fish for cakes), every check on a
   member of that mixture must reach the mixture's highest minimum.
4. Reheating overrides the product class: every step that reheats carries
   its own leftovers check at 165 F.
5. Whole cuts state the rest of at least 3 minutes in the check's own step
   (suite C at 9e04af4 reads it there too). A temperature in a step's text
   below its endpoint fails.

Cook-facing text rules (`text_violations`):

6. The step text names the thermometer and the temperature the check records.
7. No doneness by look or touch on a step without a check ("no longer pink",
   "juices run clear", "cooked through" on a protein step), and no internal
   temperature stated on a step that carries no check.
"""

from __future__ import annotations

import re
from typing import Any

FSIS_URL = ("https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/"
            "food-safety-basics/safe-temperature-chart/")
FSIS_RETRIEVED = "2026-10-11"
# The string every corpus safety check cites (unchanged from the seed tooling,
# so existing checks and new ones carry the same citation).
FSIS_SOURCE = (f"USDA FSIS Safe Minimum Internal Temperature Chart, {FSIS_URL}, "
               f"retrieved {FSIS_RETRIEVED}")
# Verbatim rows of the chart as fetched on FSIS_RETRIEVED.
FSIS_ROWS = (
    "Cook all food to these minimum internal temperatures, as measured with a "
    "food thermometer, before removing food from the heat source.",
    "Beef, Pork, Veal and Lamb Steaks, Chops and Roasts | 145 degrees F (62.8 "
    "degrees C) and allow to rest for at least 3 minutes",
    "Ground Meats | 160 degrees F (71.1 degrees C)",
    "Ground Poultry | 165 degrees F",
    "Ham, Fresh or Smoked (Uncooked) | 145 degrees F (62.8 degrees C) and allow "
    "to rest for at least 3 minutes",
    "All Poultry (Breasts, Whole Bird, Legs, Thighs, Wings, Ground Poultry, "
    "Giblets and Stuffing) | 165 degrees F (73.9 degrees C)",
    "Eggs | 160 degrees F (71.1 degrees C)",
    "Fish & Shellfish | 145 degrees F (62.8 degrees C)",
    "Leftovers | 165 degrees F (73.9 degrees C)",
    "Casseroles | 165 degrees F (73.9 degrees C)",
)

# SCHEMA.md section 3 class names. "leftovers" carries both FSIS 165 F rows
# that are about the dish rather than one food: leftovers and casseroles.
MIN_F: dict[str, int] = {
    "meat_poultry": 165,
    "meat_ground": 160,
    "meat_whole_cut_pork": 145,
    "meat_whole_cut_red": 145,
    "flesh_fish": 145,
    "flesh_shellfish": 145,
    "egg": 160,
    "leftovers": 165,
}
REST_MIN: dict[str, int] = {"meat_whole_cut_pork": 3, "meat_whole_cut_red": 3}

# ---------------------------------------------------------------------------
# classification
# ---------------------------------------------------------------------------

# Ready-to-eat or seasoning products: no doneness class of their own.
_NO_DONENESS = re.compile(
    r"\b(?:stock|broth|bouillon|fish sauce|oyster sauce|anchov\w*|canned|tinned|"
    r"smoked salmon|egg noodles?|egg pasta|buns?)\b")
# Already-cooked poultry or meat: heating it is reheating (165 F).
_PRECOOKED = re.compile(r"\b(?:cooked|rotisserie|leftover)\b|\broast (?:chicken|turkey)\b")

_CLASS_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    # ground poultry before ground meat: FSIS puts it at 165 F, not 160 F
    (re.compile(r"\b(?:ground|minced)\s+(?:chicken|turkey)\b|\b(?:chicken|turkey)\s+"
                r"(?:mince|sausages?|burgers?|meatballs?)\b"), "meat_poultry"),
    (re.compile(r"\b(?:ground|minced)\s+(?:beef|pork|lamb|veal|meat)\b|"
                r"\b(?:beef|pork|lamb|veal)\s+mince\b|\bmince\b|\bsausages?\b|"
                r"\bchorizo\b|\bmeatballs?\b|\bburgers?\b"), "meat_ground"),
    (re.compile(r"\b(?:chicken|turkey|duck|goose|quail|poussin|poultry)\b"), "meat_poultry"),
    (re.compile(r"\b(?:pork|bacon|lardons?|pancetta|gammon|ham)\b"), "meat_whole_cut_pork"),
    (re.compile(r"\b(?:beef|steak|lamb|veal|venison|brisket|sirloin)\b"), "meat_whole_cut_red"),
    (re.compile(r"\b(?:shrimps?|prawns?|crab|lobster|scallops?|clams?|mussels?|oysters?|"
                r"squid|calamari|octopus|crayfish)\b"), "flesh_shellfish"),
    (re.compile(r"\b(?:fish|salmon|cod|tuna|tilapia|trout|haddock|pollock|catfish|bass|"
                r"halibut|mackerel|snapper|hake|sardines?|swordfish)\b"), "flesh_fish"),
    (re.compile(r"\beggs?\b|\byolks?\b|\begg whites?\b"), "egg"),
)

# Dish types the FSIS chart lists at 165 F (casseroles; stuffing), matched
# on the title. "Traybake" (a sheet-pan roast) and "stuffed" vegetables or
# breads are not casseroles; their ingredients set their endpoints.
MIXED_DISH_TITLE = re.compile(
    r"\b(?:casserole|gratin|lasagn[ae]|strata|hotdish|shepherd'?s pie|cottage pie|"
    r"fish pie|pot pie|moussaka|stuffing|bake)\b", re.IGNORECASE)

# Words in an ingredient name that a step uses to refer to that food.
_PROTEIN_WORDS = re.compile(
    r"\b(?:chicken|turkey|duck|goose|thighs?|breasts?|drumsticks?|wings?|legs?|"
    r"beef|steak|chuck|brisket|pork|chops?|shoulder|bacon|lardons|pancetta|ham|"
    r"sausages?|chorizo|mince|meatballs?|lamb|shanks?|veal|fish|fillets?|salmon|cod|"
    r"tuna|tilapia|trout|haddock|catfish|bass|sardines?|shrimps?|prawns?|crab|"
    r"scallops?|mussels?|clams?|squid|eggs?|yolks?)\b")

# Verbs that combine raw foods into one mixture (cakes, loaves, breading).
_MIXING = re.compile(r"\b(?:mix|mixed|work|fold|combine|bind|dredge|dip|bread|coat|beat)\w*\b",
                     re.IGNORECASE)


def ingredient_class(name: str) -> str | None:
    """The FSIS doneness class of one ingredient name, or None."""
    low = str(name).strip().lower()
    if not low or _NO_DONENESS.search(low):
        return None
    for pattern, cls in _CLASS_PATTERNS:
        if pattern.search(low):
            if cls != "egg" and _PRECOOKED.search(low):
                return "leftovers"
            return cls
    return None


def is_mixed_dish(title: str) -> bool:
    return bool(MIXED_DISH_TITLE.search(str(title)))


def required_classes(recipe: dict[str, Any]) -> dict[str, list[str]]:
    """{class: [ingredient names, or 'title ...' for a casserole]}."""
    need: dict[str, list[str]] = {}
    for line in recipe.get("ingredients", []):
        if not isinstance(line, dict):
            continue
        cls = ingredient_class(line.get("name", ""))
        if cls:
            need.setdefault(cls, []).append(str(line.get("name")))
    if is_mixed_dish(recipe.get("title", "")):
        need.setdefault("leftovers", []).append(f"title {recipe.get('title')!r}")
    return need


def _singular(word: str) -> str:
    return word[:-1] if word.endswith("s") and not word.endswith("ss") else word


def _mention_words(recipe: dict[str, Any]) -> dict[str, set[str]]:
    """{class: words a step uses for that class's ingredients}."""
    words: dict[str, set[str]] = {}
    for line in recipe.get("ingredients", []):
        if not isinstance(line, dict):
            continue
        name = str(line.get("name", "")).lower()
        cls = ingredient_class(name)
        if not cls:
            continue
        for w in _PROTEIN_WORDS.findall(name):
            words.setdefault(cls, set()).add(_singular(w))
    return words


def classes_in_text(text: str, mention: dict[str, set[str]]) -> set[str]:
    toks = {_singular(t) for t in re.findall(r"[a-z]+", str(text).lower())}
    return {cls for cls, ws in mention.items() if ws & toks}


def mixtures(steps: list[dict[str, Any]],
             mention: dict[str, set[str]]) -> list[tuple[int, set[str]]]:
    """(step index, class set) for each step without a check that mixes
    foods of several classes. Only checks after that step cook the mixture."""
    out = []
    for i, step in enumerate(steps):
        if isinstance(step.get("safety"), dict):
            continue
        text = str(step.get("text", ""))
        here = classes_in_text(text, mention)
        if len(here) >= 2 and _MIXING.search(text):
            out.append((i, here))
    return out


def _with_mixtures(i: int, classes: set[str], groups: list[tuple[int, set[str]]]) -> set[str]:
    out = set(classes)
    for at, g in groups:
        if at < i and g & out:
            out |= g
    return out


# ---------------------------------------------------------------------------
# text patterns
# ---------------------------------------------------------------------------

REHEAT_TEXT = re.compile(r"\bre-?heat\w*|\bre-?warm\w*", re.IGNORECASE)
_THERMOMETER = re.compile(r"\bthermometer\b", re.IGNORECASE)
# An internal temperature in Fahrenheit. Oven settings start above 190 F, so
# 100-190 F is read as a doneness or holding temperature.
_INTERNAL_F = re.compile(r"\b(1[0-8]\d|190)\s*(?:°\s*F|degrees F|F)\b")
_REST = re.compile(r"\brest\w*\b[^.;]{0,80}?\b(\d+)\s*(?:-\s*\d+\s*)?(?:min|minutes)\b",
                   re.IGNORECASE)
# Doneness stated by appearance or touch (FSIS "Doneness Versus Safety").
_DONENESS_ANY = re.compile(
    r"\b(?:no longer pink|no pink|juices run clear|flakes? (?:easily|apart|with a fork))\b",
    re.IGNORECASE)
_DONENESS_ON_PROTEIN = re.compile(
    r"\b(?:cooked through|opaque|no longer translucent|firm to the touch|until (?:just )?"
    r"(?:done|set|firm)|fully set|are set|is set)\b", re.IGNORECASE)


# A yolk served runny has not reached the egg endpoint, whatever the white
# reads (FoodSafety.gov: raw eggs, "cook until yolk and white are firm").
_SOFT_YOLK = re.compile(
    r"\b(?:jammy|runny|soft|liquid|molten)\s+yolks?\b|"
    r"\byolks?\b[^.;]{0,20}\b(?:jammy|runny|soft|liquid|molten)\b", re.IGNORECASE)


def text_temps(text: str) -> list[int]:
    return [int(m.group(1)) for m in _INTERNAL_F.finditer(str(text))]


# A check counts only when a sentence tells the cook to measure the food and
# read the endpoint. Keyword presence is not enough: "a thermometer reading
# 165 F is unnecessary" names both and instructs neither.
_CLAUSE_BREAK = re.compile(r"(?<=[.;!?])\s+|\s+—\s+")
# A negation counts when it governs the measurement or the rest ("do not
# rest", "without a thermometer", "a reading is unnecessary"), not when it
# sits elsewhere in the clause ("no longer pink", "without peeking").
_MEASURE_WORD = (r"(?:thermometer|read|reads|reading|check|checking|measure|measuring|"
                 r"rest|resting|temperature)")
_NEGATION = re.compile(
    r"\b(?:not|no|never|don't|do not|doesn't|does not|needn't|need not|no need to|without|"
    r"skip|ignore|instead of|rather than)(?:\W+\w+)?\W+(?:a |the )?(?:food |instant-read )?"
    + _MEASURE_WORD + r"\b"
    r"|\b" + _MEASURE_WORD + r"\b[^.;]{0,40}\b(?:unnecessary|optional|not needed|"
    r"isn't needed|is not needed|not required)\b", re.IGNORECASE)
_MEASURE = re.compile(
    r"\b(?:reads?|reading|reach(?:es|ed)?|registers?|hits?|check(?:s|ed)?|"
    r"done at|must read|should read)\b", re.IGNORECASE)
_HEAT_SETTING = re.compile(r"\b(?:oven|preheat|broiler|grill|bake at|roast at)\b",
                           re.IGNORECASE)


def clauses(text: str) -> list[str]:
    return [c for c in _CLAUSE_BREAK.split(str(text)) if c.strip()]


def affirmative_check(text: str, temp: int) -> bool:
    """True when one clause instructs a thermometer reading of `temp` F in the
    food: names the thermometer, a measuring verb and the temperature, is not
    negated, and does not tie the temperature to an oven or grill setting."""
    deg = re.compile(rf"\b{int(temp)}\s*(?:°\s*F|degrees F|F)\b")
    for c in clauses(text):
        if not (_THERMOMETER.search(c) and _MEASURE.search(c)) or _NEGATION.search(c):
            continue
        for m in deg.finditer(c):
            near = c[max(0, m.start() - 25):m.end() + 12]
            if not _HEAT_SETTING.search(near):
                return True
    return False


def stated_rest(text: str) -> int | None:
    """Minutes of rest an un-negated clause tells the cook to give, or None."""
    rests = [int(m.group(1)) for c in clauses(text) if not _NEGATION.search(c)
             for m in _REST.finditer(c)]
    return max(rests) if rests else None


# ---------------------------------------------------------------------------
# the gate
# ---------------------------------------------------------------------------


def _is_num(x: Any) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _checks(recipe: dict[str, Any], out: list[str]) -> list[tuple[int, dict[str, Any]]]:
    rid = recipe.get("id", "?")
    checks = []
    for i, step in enumerate(recipe.get("steps", [])):
        chk = step.get("safety") if isinstance(step, dict) else None
        if chk is None:
            continue
        if not isinstance(chk, dict):
            out.append(f"{rid}: step[{i}] safety is not an object")
            continue
        checks.append((i, chk))
    return checks


def endpoint_violations(recipe: dict[str, Any]) -> list[str]:
    """Rules 1-5: every food reaches its FSIS endpoint (empty list = passes)."""
    rid = recipe.get("id", "?")
    out: list[str] = []
    steps = [s if isinstance(s, dict) else {} for s in recipe.get("steps", [])]
    mention = _mention_words(recipe)
    mixed = is_mixed_dish(recipe.get("title", ""))
    groups = mixtures(steps, mention)
    checks = _checks(recipe, out)

    def dish_check(i: int, chk: dict[str, Any]) -> bool:
        """A 165 F check on the finished casserole (not a later reheat)."""
        return mixed and chk.get("class") == "leftovers" and not steps[i].get("reheat")

    for i, chk in checks:
        cls, temp = chk.get("class"), chk.get("temp_f")
        text = str(steps[i].get("text", ""))
        if cls not in MIN_F:
            out.append(f"{rid}: step[{i}] safety class {cls!r} is not an FSIS class")
            continue
        if not _is_num(temp) or temp < MIN_F[cls]:
            out.append(f"{rid}: step[{i}] {cls} endpoint {temp!r} F is below the FSIS "
                       f"minimum {MIN_F[cls]} F")
            continue
        if chk.get("method") != "thermometer":
            out.append(f"{rid}: step[{i}] safety method must be 'thermometer'")
        source = str(chk.get("source", ""))
        if not ("fsis.usda.gov" in source
                or "USDA FSIS Safe Minimum Internal Temperature Chart" in source):
            out.append(f"{rid}: step[{i}] safety check does not cite the USDA FSIS chart")
        low = [t for t in text_temps(text) if t < temp]
        if low:
            out.append(f"{rid}: step[{i}] step text states {low} °F, below the step's "
                       f"{int(temp)} °F endpoint")
        if cls in REST_MIN:
            rest = stated_rest(text)
            if rest is None or rest < REST_MIN[cls]:
                out.append(f"{rid}: step[{i}] whole-cut {cls} check must tell the cook, in "
                           f"the same step, to rest the meat at least {REST_MIN[cls]} minutes")
        # rule 3: foods cooked or mixed together reach the strictest endpoint
        together = _with_mixtures(i, classes_in_text(text, mention) | {cls}, groups)
        if dish_check(i, chk):
            together.add("leftovers")
        strictest = max(MIN_F[c] for c in together)
        if temp < strictest:
            worst = sorted(c for c in together if MIN_F[c] == strictest)
            out.append(f"{rid}: step[{i}] cooks {sorted(together)} together but its "
                       f"endpoint is {int(temp)} °F; the strictest applicable is "
                       f"{strictest} °F ({', '.join(worst)})")

    # an egg served with a soft yolk misses the egg endpoint
    if "egg" in required_classes(recipe):
        for i, step in enumerate(steps):
            m = _SOFT_YOLK.search(str(step.get("text", "")))
            if m:
                out.append(f"{rid}: step[{i}] serves the yolk {m.group(0)!r}; eggs reach "
                           "160 °F with yolk and white firm")

    # rule 4: reheating overrides the product class
    for i, step in enumerate(steps):
        if step.get("reheat") or REHEAT_TEXT.search(str(step.get("text", ""))):
            chk = step.get("safety")
            if not isinstance(chk, dict) or chk.get("class") != "leftovers":
                out.append(f"{rid}: step[{i}] reheats food but carries no 165 °F leftovers "
                           "check of its own")
            if not step.get("reheat"):
                out.append(f"{rid}: step[{i}] describes reheating but is not flagged reheat")

    # rule 2: every required class is covered
    for cls, why in sorted(uncovered_classes(recipe).items()):
        out.append(f"{rid}: {cls} ({', '.join(why)}) needs a thermometer check at "
                   f"{MIN_F[cls]} °F or above and none covers it")
    return out


def uncovered_classes(recipe: dict[str, Any]) -> dict[str, list[str]]:
    """Rule 2: {class: why it is required} for each required class no check covers."""
    steps = [s if isinstance(s, dict) else {} for s in recipe.get("steps", [])]
    mention = _mention_words(recipe)
    mixed = is_mixed_dish(recipe.get("title", ""))
    groups = mixtures(steps, mention)
    checks = _checks(recipe, [])
    out: dict[str, list[str]] = {}
    for cls, why in required_classes(recipe).items():
        casserole = any(w.startswith("title ") for w in why)
        covered = False
        for i, chk in checks:
            ccls, temp = chk.get("class"), chk.get("temp_f")
            if ccls not in MIN_F or not _is_num(temp) or temp < MIN_F[cls]:
                continue
            finished_dish = mixed and ccls == "leftovers" and not steps[i].get("reheat")
            if cls == "leftovers":
                # a casserole needs its finished-dish check; reheated cooked
                # meat is covered by any leftovers check
                covered = finished_dish if casserole else ccls == "leftovers"
            else:
                text = str(steps[i].get("text", ""))
                cooked_here = _with_mixtures(i, classes_in_text(text, mention) | {ccls}, groups)
                covered = cls in cooked_here or finished_dish
            if covered:
                break
        if not covered:
            out[cls] = why
    return out


def food_words(name: str) -> list[str]:
    """The words of an ingredient name a step would use for the food."""
    return _PROTEIN_WORDS.findall(str(name).lower())


def text_violations(recipe: dict[str, Any]) -> list[str]:
    """Rules 6-7: the cook reads the check in the step itself."""
    rid = recipe.get("id", "?")
    out: list[str] = []
    steps = [s if isinstance(s, dict) else {} for s in recipe.get("steps", [])]
    mention = _mention_words(recipe)
    need = required_classes(recipe)
    for i, chk in _checks(recipe, out):
        text = str(steps[i].get("text", ""))
        cls, temp = chk.get("class"), chk.get("temp_f")
        if not _THERMOMETER.search(text):
            out.append(f"{rid}: step[{i}] {cls} check is metadata only: the step text "
                       "never tells the cook to use a thermometer")
        elif _is_num(temp) and not affirmative_check(text, int(temp)):
            out.append(f"{rid}: step[{i}] step text does not tell the cook to read "
                       f"{int(temp)} °F on a thermometer in the food, the endpoint its "
                       f"{cls} check records")
    for i, step in enumerate(steps):
        if isinstance(step.get("safety"), dict):
            continue
        text = str(step.get("text", ""))
        if need and (_DONENESS_ANY.search(text) or (
                _DONENESS_ON_PROTEIN.search(text) and classes_in_text(text, mention))):
            out.append(f"{rid}: step[{i}] states doneness by look or touch with no "
                       "thermometer check")
        temps = text_temps(text)
        if temps:
            out.append(f"{rid}: step[{i}] states an internal temperature {temps} °F but "
                       "carries no safety check")
    return out


def safety_violations(recipe: dict[str, Any]) -> list[str]:
    """Every food-safety rule the recipe breaks (empty list = passes)."""
    return endpoint_violations(recipe) + text_violations(recipe)
