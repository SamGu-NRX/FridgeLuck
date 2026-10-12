"""Composition gate for allergen and diet claims (SPEC 3.1, SCHEMA.md section 4).

A claim such as "dairy-free" says something about every ingredient in the
recipe, so it holds only when the composition of every ingredient is known.
The suite C scanner pinned at 26c7004 skipped ingredient names its alias
table did not recognise and then accepted an empty conflict list, which let
fl-original-0065 claim dairy-free with "ghee or vegetable oil" in it.

`claim_problems` refuses a claim when:

1. an ingredient name does not resolve exactly in the allergen alias table
   (suite C's allergens.json): its composition is unknown, and unknown blocks
   every claim;
2. a line offers alternatives ("ghee or vegetable oil"): each alternative
   must resolve, and the line carries the classes of all of them;
3. the ingredient resolves but its composition depends on the product
   (LABEL_DEPENDENT): stock may contain milk, wheat or meat; cheese may use
   animal rennet; tamari and curry powder may contain wheat;
4. a step names a conflicting food the ingredient list does not (a serving
   suggestion of sour cream on a dairy-free recipe);
5. the recorded conflicts differ from the recomputed scan, or the scan finds
   a forbidden class.

The gate never adds a claim. `strip_unproven_claims.py` removes the claims it
refuses from the corpus.
"""

from __future__ import annotations

import re
from typing import Any

CLAIM_TYPES = ("vegetarian", "vegan", "gluten-free", "dairy-free", "nut-free")

_ALTERNATIVE = re.compile(r"\s+(?:or|and/or)\s+|\s*/\s*")

# (pattern on the resolved name, claims it leaves unknown, why)
LABEL_DEPENDENT: tuple[tuple[re.Pattern[str], frozenset[str], str], ...] = (
    (re.compile(r"\b(?:stock|broth|bouillon)\b"),
     frozenset({"vegetarian", "vegan", "dairy-free", "gluten-free"}),
     "stock varies by product and may contain meat, milk or wheat"),
    (re.compile(r"\bmashed potato"), frozenset({"vegan", "dairy-free"}),
     "mashed potatoes are usually made with butter and milk"),
    (re.compile(r"\b(?:bread|pitas?|pitta|naan|tortillas?|breadcrumbs|panko|buns?|wraps?)\b"),
     frozenset({"vegetarian", "vegan", "dairy-free"}),
     "breads, tortillas and crumbs may contain milk, egg or lard"),
    (re.compile(r"\b(?:pasta|orzo|wheat noodles)\b"), frozenset({"vegan"}),
     "dried pasta and wheat noodles may contain egg"),
    (re.compile(r"\bsausages?\b"), frozenset({"dairy-free", "gluten-free"}),
     "sausages may contain milk or wheat fillers"),
    (re.compile(r"\b(?:curry powder|chaat masala)\b"), frozenset({"gluten-free"}),
     "curry powder may contain wheat flour; chaat masala contains asafoetida, "
     "usually cut with wheat flour"),
    (re.compile(r"\bmiso\b"), frozenset({"gluten-free"}), "miso may be made with barley"),
    (re.compile(r"\btamari\b"), frozenset({"gluten-free"}), "some tamari contains wheat"),
    (re.compile(r"\boats\b"), frozenset({"gluten-free"}),
     "oats are gluten-free only when certified, because of cross-contact"),
    (re.compile(r"\bbaking powder\b"), frozenset({"gluten-free"}),
     "some baking powders use wheat starch"),
    (re.compile(r"\bchipotle\b"), frozenset({"gluten-free"}),
     "some chipotles in adobo contain wheat flour"),
    (re.compile(r"\b(?:cheddar|parmesan|mozzarella|feta|halloumi|cheese)\b"),
     frozenset({"vegetarian", "vegan"}), "cheese may be made with animal rennet"),
    (re.compile(r"\byog(?:h)?urt\b"), frozenset({"vegetarian", "vegan"}),
     "some yogurts contain gelatin"),
    (re.compile(r"\bsugar\b"), frozenset({"vegan"}), "cane sugar may be refined with bone char"),
)

# Phrases that contain a conflicting word but are not that food, removed
# only for the claim they do not contradict: "peanut butter" is not dairy,
# so it is exempt from the dairy-free scan, and it stays in the nut-free scan.
_NOT_DAIRY = (r"(?:coconut|oat|almond|soy|rice|cashew) (?:milk|cream)|peanut butter|"
              r"almond butter|cashew butter|butter beans?|butternut|cream of tartar")
STEP_EXEMPT: dict[str, re.Pattern[str]] = {
    "dairy-free": re.compile(rf"\b(?:{_NOT_DAIRY})\b"),
    "vegan": re.compile(rf"\b(?:{_NOT_DAIRY}|eggplants?)\b"),
    "gluten-free": re.compile(r"\b(?:rice noodles|rice flour|corn ?flour|chickpea flour)\b"),
    "nut-free": re.compile(r"\b(?:nutmeg|butternut|doughnuts?)\b"),
}

# Compound foods a step can name, and the claims each one contradicts.
STEP_COMPOUNDS: tuple[tuple[re.Pattern[str], frozenset[str]], ...] = (
    (re.compile(r"\bpesto\b"),
     frozenset({"nut-free", "dairy-free", "vegan", "vegetarian"})),  # nuts, parmesan
    (re.compile(r"\b(?:mayonnaise|mayo|aioli)\b"), frozenset({"vegan"})),  # egg
    (re.compile(r"\bworcestershire\b"),
     frozenset({"vegetarian", "vegan", "gluten-free"})),  # anchovy, malt vinegar
    (re.compile(r"\b(?:fish|oyster) sauce\b"), frozenset({"vegetarian", "vegan"})),
    (re.compile(r"\b(?:teriyaki|hoisin|miso|gochujang)\b"), frozenset({"gluten-free"})),
    (re.compile(r"\bcustard\b"), frozenset({"dairy-free", "vegan"})),
    (re.compile(r"\b(?:nutella|praline|marzipan|frangipane)\b"), frozenset({"nut-free"})),
)

# Foods a step can name that contradict a claim.
STEP_CONFLICTS: dict[str, re.Pattern[str]] = {
    "dairy-free": re.compile(
        r"\b(?:butter|buttermilk|ghee|cheese|cheddar|parmesan|mozzarella|feta|halloumi|"
        r"paneer|ricotta|cream|milk|yog(?:h)?urt)\b"),
    "gluten-free": re.compile(
        r"\b(?:flour|bread|breadcrumbs|panko|pasta|noodles|couscous|soy sauce|wheat|barley|"
        r"naan|pitas?|pitta|toast|buns?|croutons)\b"),
    "vegetarian": re.compile(
        r"\b(?:chicken|beef|pork|bacon|lamb|ham|sausages?|chorizo|fish|tuna|salmon|cod|"
        r"shrimp|prawns?|anchov\w*|gelatin|stock|broth|lard)\b"),
    "nut-free": re.compile(
        r"\b(?:nuts?|almonds?|cashews?|peanuts?|walnuts?|pecans?|pistachios?|hazelnuts?|"
        r"coconut)\b"),
}
STEP_CONFLICTS["vegan"] = re.compile(
    STEP_CONFLICTS["vegetarian"].pattern + "|"
    + r"\b(?:eggs?|honey|butter|ghee|cheese|cheddar|parmesan|mozzarella|feta|cream|milk|"
      r"yog(?:h)?urt)\b")


def _norm(name: Any) -> str:
    return str(name).strip().lower()


def resolve(name: str, table: dict[str, Any]) -> tuple[set[str], list[str]]:
    """(allergen classes, unknown parts) for one ingredient line name."""
    aliases = table["ingredient_aliases"]
    ingredients = table["ingredients"]
    classes: set[str] = set()
    unknown: list[str] = []
    parts = [p for p in _ALTERNATIVE.split(_norm(name)) if p]
    for part in parts or [_norm(name)]:
        key = aliases.get(part)
        if key and key in ingredients:
            classes |= set(ingredients[key].get("classes", []))
        else:
            unknown.append(part)
    return classes, unknown


def claim_problems(recipe: dict[str, Any], table: dict[str, Any]) -> dict[str, list[str]]:
    """{claim: reasons it is not proven} for each claim the recipe carries."""
    claim_defs = table["claims"]
    out: dict[str, list[str]] = {}
    lines = [l for l in recipe.get("ingredients", []) if isinstance(l, dict)]
    classes: set[str] = set()
    unknown: list[str] = []
    alternatives: list[str] = []
    for line in lines:
        name = _norm(line.get("name", ""))
        if _ALTERNATIVE.search(name):
            alternatives.append(name)
        c, u = resolve(name, table)
        classes |= c
        unknown += u
    steps_text = " ".join(str(s.get("text", "")) for s in recipe.get("steps", [])
                          if isinstance(s, dict)).lower()

    for claim in recipe.get("claims", []):
        cname = claim.get("claim") if isinstance(claim, dict) else None
        reasons: list[str] = []
        if cname not in claim_defs:
            out[str(cname)] = [f"unknown claim type {cname!r}"]
            continue
        if unknown:
            reasons.append(f"composition unknown for {sorted(set(unknown))}")
        if alternatives:
            reasons.append(f"line offers alternatives {alternatives}; each must be known "
                           "and allowed")
        for line in lines:
            name = _norm(line.get("name", ""))
            for pattern, blocked, why in LABEL_DEPENDENT:
                if cname in blocked and pattern.search(name):
                    reasons.append(f"{name!r}: {why}")
        conflict = STEP_CONFLICTS.get(cname)
        if conflict:
            exempt = STEP_EXEMPT.get(cname)
            scanned = exempt.sub(" ", steps_text) if exempt else steps_text
            hit = conflict.search(scanned)
            if hit:
                reasons.append(f"a step names {hit.group(0)!r}")
        for pattern, blocked in STEP_COMPOUNDS:
            hit = pattern.search(steps_text)
            if hit and cname in blocked:
                reasons.append(f"a step names {hit.group(0)!r}, a compound food that "
                               f"contradicts {cname}")
        forbid = set(claim_defs[cname].get("forbids", []))
        conflicts = sorted(classes & forbid)
        evidence = claim.get("evidence")
        recorded = sorted(evidence.get("conflicts", [])) if isinstance(evidence, dict) else None
        if recorded != conflicts:
            reasons.append(f"recorded conflicts {recorded} differ from the scan {conflicts}")
        if conflicts:
            reasons.append(f"contains forbidden classes {conflicts}")
        if reasons:
            out[cname] = reasons
    return out
