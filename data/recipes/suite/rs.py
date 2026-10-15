"""RS — the recipes-grammar format for the FridgeLuck corpus, and its linter.

RS is the structured recipe schema suite C validates against. It encodes the
SPEC 3.5 rule "structured or not shipped":

- ingredient lines carry quantity evidence: ``weighed``, ``source_grams``,
  ``household`` (a household measure WITH a conversion to grams from the
  corpus conversions table), or ``unknown`` — never an invented mass;
- steps split at timer and action boundaries where real: a ``timer_min`` only
  where the step has a natural one;
- doneness for meat, poultry, fish, eggs and leftovers is a thermometer check
  against the USDA FSIS safe minimum internal temperatures (SPEC 3.1), never
  colour or time alone;
- every allergen/diet claim carries machine evidence (a recomputed allergen
  scan) or is stripped by the linter and counted (SPEC 3.5 / suite C bar).

The linter is deliberately independent of how results are emitted: the suite
re-derives every metric from the corpus the linter returns, so a lying emitter
cannot upgrade a violated bar (mirrors the runner's liar scenario).
"""

from __future__ import annotations

import re
from typing import Any

# Quantity-evidence kinds that RESOLVE a line (SPEC: weighed, source grams,
# or household measure with a conversion). ``unknown`` is honest but unresolved.
RESOLVED_KINDS = ("weighed", "source_grams", "household")
ALL_KINDS = RESOLVED_KINDS + ("unknown",)

# Doneness language that is forbidden on animal-protein steps without a
# thermometer check (SPEC 3.1: never by colour or time alone).
_COLOUR_OR_TIME_DONENESS = re.compile(
    r"(?:until|when)?\s*(?:golden|no longer pink|cooked through|"
    r"no longer translucent|opaque|browned through|firm to the touch)\b",
    re.IGNORECASE,
)

# USDA FSIS safe minimum internal temperatures (°F). The FSIS chart is the
# reviewed source named by SPEC 3.1. Temperatures as published by the FSIS
# safe minimum internal temperature chart; re-verify against the live chart
# when the corpus task takes ownership of the rulebook.
FSIS_TEMP_F = {
    "meat_poultry": 165,       # whole cuts of chicken / turkey
    "meat_ground": 160,        # ground beef, pork, lamb, sausage
    "meat_whole_cut_pork": 145,
    "meat_whole_cut_red": 145, # beef, veal, lamb whole cuts
    "flesh_fish": 145,
    "flesh_shellfish": 145,
    "egg": 160,
    "leftovers": 165,          # reheating any leftover
}

# Doneness classes: animal FLESH classes that REQUIRE a thermometer check.
# (Allergen classes such as `fish` also appear on fish sauce or stock, which
# need no doneness check — the flesh_* split keeps those apart.)
SAFETY_CLASSES = ("meat_poultry", "meat_ground", "meat_whole_cut_pork",
                  "meat_whole_cut_red", "flesh_fish", "flesh_shellfish", "egg")

REQUIRED_RECIPE_FIELDS = (
    "rs_version", "id", "title", "cuisine", "meal_slots", "minutes",
    "servings", "ingredients", "steps", "source_ref",
)

RS_VERSION = "1"


def class_of_temperature(temp_f: float) -> float | None:
    """The highest FSIS minimum this temperature satisfies (diagnostic only;
    the linter checks the named class's minimum, not the best match)."""
    mins = [t for t in FSIS_TEMP_F.values() if temp_f >= t]
    return max(mins) if mins else None


# ---------------------------------------------------------------------------
# lint
# ---------------------------------------------------------------------------


def lint_recipe(recipe: dict[str, Any], *, cuisines: set[str],
                meal_slots: set[str], conversions: dict[str, dict[str, float]],
                allergen_scan: "AllergenScanner") -> list[str]:
    """Return the list of lint violations for one RS recipe (empty = pass).

    `allergen_scan.verify_claim` re-computes each claim's evidence from the
    ingredient table; a claim whose evidence is missing or contradicted is
    reported as an unchecked claim (the suite strips it and counts it).
    """
    v: list[str] = []
    rid = recipe.get("id", "?")

    # R1 schema ------------------------------------------------------------
    for field in REQUIRED_RECIPE_FIELDS:
        if field not in recipe:
            v.append(f"{rid}: R1 missing required field {field!r}")
    if recipe.get("rs_version") != RS_VERSION:
        v.append(f"{rid}: R1 rs_version must be {RS_VERSION!r}")
    if not isinstance(recipe.get("ingredients"), list) or not recipe.get("ingredients"):
        v.append(f"{rid}: R1 ingredients must be a non-empty list")
        recipe["ingredients"] = []
    if not isinstance(recipe.get("steps"), list) or not recipe.get("steps"):
        v.append(f"{rid}: R1 steps must be a non-empty list")
        recipe["steps"] = []
    if recipe.get("cuisine") not in cuisines:
        v.append(f"{rid}: R1 unknown cuisine {recipe.get('cuisine')!r}")
    slots = recipe.get("meal_slots")
    if not isinstance(slots, list) or not slots or not set(slots) <= meal_slots:
        v.append(f"{rid}: R1 meal_slots {slots!r} outside declared slots")

    # R2 quantity evidence per line ----------------------------------------
    for i, line in enumerate(recipe["ingredients"]):
        qty = line.get("qty") if isinstance(line, dict) else None
        if not isinstance(qty, dict):
            v.append(f"{rid}: R2 ingredient[{i}] {line.get('name', '?')!r} has no quantity evidence")
            continue
        kind = qty.get("kind")
        if kind not in ALL_KINDS:
            v.append(f"{rid}: R2 ingredient[{i}] {line.get('name', '?')!r} qty.kind {kind!r} is not quantity evidence")
        elif kind == "household":
            conv_ref = qty.get("conversion_ref")
            grams = qty.get("grams")
            unit = qty.get("unit")
            value = qty.get("value")
            if not isinstance(conv_ref, str) or conv_ref not in conversions:
                v.append(f"{rid}: R2 ingredient[{i}] {line.get('name', '?')!r} household measure has no conversion in the table (invented mass)")
            elif not conversions[conv_ref].get("grams_per_unit"):
                v.append(f"{rid}: R2 ingredient[{i}] {line.get('name', '?')!r} conversion {conv_ref!r} has no grams_per_unit")
            if not isinstance(unit, str) or not unit:
                v.append(f"{rid}: R2 ingredient[{i}] {line.get('name', '?')!r} household measure missing unit")
            if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {line.get('name', '?')!r} household measure missing positive value")
            if grams is not None and (not isinstance(grams, (int, float)) or isinstance(grams, bool) or grams <= 0):
                v.append(f"{rid}: R2 ingredient[{i}] {line.get('name', '?')!r} grams must be positive when present")
        elif kind in ("weighed", "source_grams"):
            grams = qty.get("grams")
            if not isinstance(grams, (int, float)) or isinstance(grams, bool) or grams <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {line.get('name', '?')!r} {kind} requires positive grams")

    # R3 safety: thermometer doneness for animal flesh -------------------
    classes = set(recipe.get("_classes", []) or [])
    needs_safety = classes & set(SAFETY_CLASSES)
    has_reheat = any(isinstance(s, dict) and s.get("reheat") for s in recipe["steps"])
    safety_checks = [
        s.get("safety") for s in recipe["steps"]
        if isinstance(s, dict) and isinstance(s.get("safety"), dict)
    ]
    if (needs_safety or has_reheat) and not safety_checks:
        v.append(f"{rid}: R3 animal-protein/leftover recipe has no thermometer doneness check (colour/time alone is forbidden)")
    for chk in safety_checks:
        temp = chk.get("temp_f")
        cls = chk.get("class")
        if cls not in FSIS_TEMP_F:
            v.append(f"{rid}: R3 safety check names unknown class {cls!r} (must name an FSIS class)")
            continue
        if not isinstance(temp, (int, float)) or isinstance(temp, bool):
            v.append(f"{rid}: R3 safety check missing numeric temp_f")
            continue
        if temp < FSIS_TEMP_F[cls]:
            v.append(f"{rid}: R3 safety temp_f {temp} below the FSIS minimum {FSIS_TEMP_F[cls]} for {cls}")
        if chk.get("method") != "thermometer":
            v.append(f"{rid}: R3 safety check method must be 'thermometer'")
        if not chk.get("source"):
            v.append(f"{rid}: R3 safety check must cite its source (USDA FSIS)")
    # doneness by colour/time alone on animal-protein steps
    for i, step in enumerate(recipe["steps"]):
        if not isinstance(step, dict):
            continue
        text = str(step.get("text", ""))
        if (needs_safety and _COLOUR_OR_TIME_DONENESS.search(text)
                and not isinstance(step.get("safety"), dict)):
            v.append(f"{rid}: R3 step[{i}] states doneness by colour/time without a thermometer check")

    # R4 allergen/diet claims must carry machine evidence -------------------
    for claim in recipe.get("claims", []):
        verdict = allergen_scan.verify_claim(recipe, claim)
        if verdict is not True:
            v.append(f"{rid}: R4 claim {claim.get('claim', '?')!r} unchecked: {verdict}")

    # R5 timers: only natural ones, bounded; reheat steps flagged as such ----
    for i, step in enumerate(recipe["steps"]):
        if not isinstance(step, dict):
            continue
        t = step.get("timer_min")
        if t is not None:
            if not isinstance(t, (int, float)) or isinstance(t, bool) or not (0 < t <= 240):
                v.append(f"{rid}: R5 step[{i}] timer_min {t!r} is not a real timer (1-240 min)")

    # R6 rights linkage is checked by the suite (rights.py) before lint.
    return v


def lint_corpus(recipes: list[dict[str, Any]], *, cuisines: set[str],
                meal_slots: set[str], conversions: dict[str, dict[str, float]],
                allergen_scan: "AllergenScanner") -> dict[str, Any]:
    """Lint every recipe; return per-recipe violations and corpus line stats."""
    report: dict[str, Any] = {
        "recipes_with_violations": {},
        "total_lines": 0,
        "resolved_lines": 0,
        "stripped_claims": 0,
        "unchecked_claims": 0,
    }
    for recipe in recipes:
        violations = lint_recipe(
            recipe, cuisines=cuisines, meal_slots=meal_slots,
            conversions=conversions, allergen_scan=allergen_scan,
        )
        if violations:
            report["recipes_with_violations"][recipe["id"]] = violations
        # quantity evidence stats over ALL ingredient lines
        for line in recipe.get("ingredients", []):
            report["total_lines"] += 1
            qty = line.get("qty") if isinstance(line, dict) else None
            if isinstance(qty, dict) and qty.get("kind") in RESOLVED_KINDS:
                # a household line only counts when its conversion really exists
                if qty.get("kind") == "household":
                    ref = qty.get("conversion_ref")
                    if isinstance(ref, str) and conversions.get(ref, {}).get("grams_per_unit"):
                        report["resolved_lines"] += 1
                else:
                    report["resolved_lines"] += 1
        # claims: evidence-backed stay; unchecked are stripped and counted
        kept_claims = []
        for claim in recipe.get("claims", []):
            verdict = allergen_scan.verify_claim(recipe, claim)
            if verdict is True:
                kept_claims.append(claim)
            else:
                report["stripped_claims"] += 1
                report["unchecked_claims"] += 1
        if report["recipes_with_violations"].get(recipe["id"]) is None and len(kept_claims) != len(recipe.get("claims", [])):
            # lint passed but claims were stripped: not a violation, only a count
            pass
        recipe["claims"] = kept_claims
    report["passed"] = [
        r["id"] for r in recipes if r["id"] not in report["recipes_with_violations"]
    ]
    return report


# ---------------------------------------------------------------------------
# allergen / diet claims: the scanner is the only evidence source
# ---------------------------------------------------------------------------


class AllergenScanner:
    """Verify allergen/diet claims by scanning ingredient classes.

    Evidence is recomputed here from `allergens.json`; a claim with no
    evidence field, or whose recorded evidence disagrees with the recomputed
    scan, is *unchecked* and must be stripped (SPEC 3.5).
    """

    def __init__(self, table: dict[str, Any]) -> None:
        self.table = table
        self.claim_defs: dict[str, dict[str, Any]] = table["claims"]

    def classes_for(self, recipe: dict[str, Any]) -> set[str]:
        classes: set[str] = set()
        for line in recipe.get("ingredients", []):
            name = line.get("name", "") if isinstance(line, dict) else ""
            key = self.table["ingredient_aliases"].get(str(name).strip().lower())
            if key:
                classes |= set(self.table["ingredients"][key].get("classes", []))
        return classes

    def verify_claim(self, recipe: dict[str, Any], claim: dict[str, Any]) -> Any:
        """True when the claim is backed by a matching recomputed scan;
        a human-readable reason string when it is unchecked."""
        cname = claim.get("claim")
        if cname not in self.claim_defs:
            return f"unknown claim type {cname!r}"
        if not isinstance(claim.get("evidence"), dict):
            return "claim carries no evidence field"
        forbid = set(self.claim_defs[cname].get("forbids", []))
        present = self.classes_for(recipe)
        conflicts = sorted(present & forbid)
        recorded = set(claim["evidence"].get("conflicts", []))
        if conflicts != sorted(recorded):
            return (f"evidence disagrees with recomputed scan "
                    f"(recorded {sorted(recorded)}, recomputed {conflicts})")
        if conflicts:
            return f"ingredients contain forbidden classes {conflicts}"
        return True
