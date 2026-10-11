"""RS — the recipes-grammar format for the FridgeLuck corpus, and its linter.

RS is the structured recipe schema suite C validates against. It encodes the
SPEC 3.5 rule "structured or not shipped":

- ingredient lines carry quantity evidence: ``weighed`` (a recorded scale
  measurement in provenance — a builder estimate is never weighed),
  ``source_grams``, ``household`` (a household measure whose line carries its
  own cited conversion: ``conversion_ref`` plus the resolved ``grams``), or
  ``unknown`` — never an invented mass. An unresolvable conversion_ref is
  unresolved, not weighed;
- steps split at timer and action boundaries where real: a ``timer_min`` only
  where the step has a natural one;
- doneness for meat, poultry, fish, eggs and leftovers is a thermometer check
  derived from each ingredient's ACTUAL class through the canonical
  food-safety rulebook (`data/food-safety/rules.json`, branch
  overhaul/food-safety-canon), never colour or time alone. Every required
  class must be covered at or above the class minimum, whole cuts must state
  the required 3-minute rest, and every reheat step must carry its own
  165 F ``leftovers`` check;
- every allergen/diet claim carries machine evidence (a recomputed allergen
  scan) or is stripped by the linter and counted (SPEC 3.5 / suite C bar).
  An ingredient whose composition no table resolves makes the claim UNCHECKED
  and the allergen classification INCOMPLETE — unknown never means allowed.

The linter is deliberately independent of how results are emitted: the suite
re-derives every metric from the corpus the linter returns, so a lying emitter
cannot upgrade a violated bar (mirrors the runner's liar scenario).

Canonical sources and fail-closed behavior:

- Doneness classes, minimum temperatures, required rests, classification
  keywords and citation tokens come ONLY from the rulebook data
  (`CanonRulebook.load`: the scored tree's ``data/food-safety/rules.json``
  when present, else the pinned snapshot in ``canon/rules.json``).
- When the rulebook cannot be loaded or fails validation, doneness validation
  fails closed: every recipe with any safety-relevant signal is a violation.
  The linter never substitutes its own temperature table.
- Ingredient composition comes from the suite's interim alias table
  (``allergens.json``). The FLIngredientFacts package (overhaul task
  fl-root-ingredient-facts-f1) will replace it; until it lands, an
  unresolvable ingredient name is classification INCOMPLETE and every claim
  on the recipe is UNCHECKED — never clear.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

# Quantity-evidence kinds that RESOLVE a line (SPEC: weighed, source grams,
# or household measure with its cited conversion carried on the line).
# ``unknown`` is honest but unresolved.
RESOLVED_KINDS = ("weighed", "source_grams", "household")
ALL_KINDS = RESOLVED_KINDS + ("unknown",)

# The eight FSIS classes the canon rulebook names (data/food-safety/SCHEMA.md).
# ``leftovers`` is never an ingredient class: it is required by reheat steps
# and combination dishes (casseroles).
RS_SAFETY_CLASSES = ("meat_poultry", "meat_ground", "meat_whole_cut_pork",
                     "meat_whole_cut_red", "flesh_fish", "flesh_shellfish",
                     "egg", "leftovers")

# Ingredient-derivable classes (all of the above except leftovers).
INGREDIENT_SAFETY_CLASSES = tuple(c for c in RS_SAFETY_CLASSES if c != "leftovers")

# Doneness language that is forbidden on animal-protein steps without a
# thermometer check (SPEC 3.1: never by colour or time alone). Mirrors the
# canon rulebook's never-say set (data/food-safety README + COPY.md): the
# phrase set in data/food-safety/SCHEMA.md is this regex plus "juices run
# clear" and "no pink", which FSIS Doneness Versus Safety separately rejects.
_COLOUR_OR_TIME_DONENESS = re.compile(
    r"(?:until|when)?\s*(?:golden|no longer pink|no pink|cooked through|"
    r"no longer translucent|opaque|browned through|firm to the touch|"
    r"juices run clear)\b",
    re.IGNORECASE,
)

# Reheat language in step text: a step that describes reheating must carry the
# structured ``reheat`` flag (SCHEMA 3), and every reheat step must carry its
# own leftovers thermometer check. Kept tight (no "warm"/"microwave" alone —
# melting chocolate in a microwave is not reheating leftovers).
_REHEAT_TEXT = re.compile(r"\b(?:reheat|re-heat|rewarm|re-warm|warm up|warming up|warm through)\b",
                          re.IGNORECASE)

# Rest language in step text: "then rest for at least 3 minutes before
# carving" — rest word, then a minute count within the same sentence.
_REST_TEXT = re.compile(r"\brest\w*\b[^.]{0,60}?\b(\d+)\s*min", re.IGNORECASE)

REQUIRED_RECIPE_FIELDS = (
    "rs_version", "id", "title", "cuisine", "meal_slots", "minutes",
    "servings", "ingredients", "steps", "source_ref",
)

RS_VERSION = "1"

PINNED_CANON = Path(__file__).resolve().parent / "canon" / "rules.json"


# ---------------------------------------------------------------------------
# canonical rulebook (data/food-safety/rules.json) — the one source of truth
# ---------------------------------------------------------------------------


class CanonRulebook:
    """The validated rulebook data behind every doneness judgment.

    Built only from the canonical rules.json (scored tree first, pinned
    snapshot second). Carries per-class minimum temperatures and required
    rests, the classification keywords, and the citation tokens a corpus
    safety source must resolve against.
    """

    def __init__(self, data: dict[str, Any], source: str) -> None:
        self.source = source
        self.class_min_f: dict[str, float] = {}
        self.class_rest_min: dict[str, float] = {}
        # doneness-topic keyword -> class, longest first, word-boundary matched
        self._ingredient_rules: list[tuple[re.Pattern[str], str, str]] = []
        self._title_rules: list[tuple[re.Pattern[str], str, str]] = []
        self._citation_urls: list[str] = []
        self._citation_titles: list[str] = []
        self._org_acronyms: set[str] = set()
        self._build(data)

    # -- construction -------------------------------------------------------

    def _build(self, data: dict[str, Any]) -> None:
        if data.get("schema_version") != 1:
            raise ValueError(f"schema_version must be 1, got {data.get('schema_version')!r}")
        citations = data.get("citations")
        if not isinstance(citations, list) or not citations:
            raise ValueError("rulebook has no citations")
        for cit in citations:
            if not isinstance(cit, dict):
                raise ValueError("malformed citation entry")
            url, title = str(cit.get("url", "")), str(cit.get("title", ""))
            if url:
                self._citation_urls.append(url.lower())
            if title:
                self._citation_titles.append(title.lower())
            for tok in re.findall(r"[A-Z]{2,}", str(cit.get("org", ""))):
                self._org_acronyms.add(tok)
        if not self._citation_urls and not self._citation_titles:
            raise ValueError("rulebook citations carry no url or title to validate against")

        rules = data.get("rules")
        if not isinstance(rules, list) or not rules:
            raise ValueError("rulebook has no rules")
        for rule in rules:
            topic = rule.get("topic")
            food_class = rule.get("food_class")
            check = rule.get("check")
            if food_class is not None and food_class not in RS_SAFETY_CLASSES:
                raise ValueError(f"rule {rule.get('id')!r} names unknown food_class {food_class!r}")
            if topic not in ("doneness", "reheating") or not isinstance(check, dict):
                continue
            temp = check.get("temp_f")
            if food_class is None or not isinstance(temp, (int, float)) or isinstance(temp, bool):
                raise ValueError(f"rule {rule.get('id')!r} has no usable check (class/temp)")
            self.class_min_f[food_class] = max(self.class_min_f.get(food_class, 0), float(temp))
            self.class_rest_min[food_class] = max(
                self.class_rest_min.get(food_class, 0), float(check.get("rest_minutes") or 0))
            for kw in rule.get("match_keywords", []) or []:
                pat = re.compile(r"\b" + re.escape(str(kw).lower()) + r"\b")
                entry = (pat, food_class, str(rule.get("id", "")))
                if topic == "reheating":
                    continue  # reheating keywords must not classify ingredients
                # casserole-style rules name DISH types: they classify the
                # recipe title, never an ingredient line
                if any(d in str(kw).lower() for d in ("casserole", "lasagne", "lasagna",
                                                      "gratin", "hotdish", "bake",
                                                      "shepherd")):
                    self._title_rules.append(entry)
                else:
                    self._ingredient_rules.append(entry)
        missing = [c for c in RS_SAFETY_CLASSES if c not in self.class_min_f]
        if missing:
            raise ValueError(f"rulebook carries no minimum for class(es): {missing}")
        # longest-first keyword matching
        self._ingredient_rules.sort(key=lambda e: e[0].pattern, reverse=True)
        self._title_rules.sort(key=lambda e: e[0].pattern, reverse=True)

    # -- lookups ------------------------------------------------------------

    def classes_for_name(self, name: str) -> set[str]:
        """Doneness classes the canon assigns to one ingredient name."""
        low = str(name).strip().lower()
        return {cls for pat, cls, _ in self._ingredient_rules if pat.search(low)}

    def classes_for_title(self, title: str) -> set[str]:
        """Doneness classes the canon assigns to a dish title (combination
        dishes such as casseroles must reach the 165 F leftovers minimum)."""
        low = str(title).strip().lower()
        return {cls for pat, cls, _ in self._title_rules if pat.search(low)}

    def source_is_canonical(self, source: str) -> bool:
        """True when a corpus safety source cites the rulebook (a citation
        URL, a citation title, or a publishing body's acronym)."""
        s = str(source).lower()
        if any(u in s for u in self._citation_urls):
            return True
        if any(t in s for t in self._citation_titles):
            return True
        return any(re.search(rf"\b{re.escape(a)}\b", s) for a in self._org_acronyms)

    # -- loading ------------------------------------------------------------

    @classmethod
    def load(cls, repo_root: Path | None) -> tuple["CanonRulebook | None", str]:
        """Load the canon rulebook; returns (rulebook, provenance-or-reason).

        Precedence: the scored tree's ``data/food-safety/rules.json`` when
        ``repo_root`` carries one, else the suite's pinned snapshot
        (``canon/rules.json``, see canon/PROVENANCE.md). Any parse or
        validation failure returns (None, reason) — callers must fail closed.
        """
        candidates: list[tuple[Path, str]] = []
        if repo_root is not None:
            candidates.append((Path(repo_root) / "data" / "food-safety" / "rules.json",
                               "scored tree data/food-safety/rules.json"))
        candidates.append((PINNED_CANON,
                           f"suite-pinned snapshot canon/rules.json "
                           f"(overhaul/food-safety-canon @ 2e03467d)"))
        tried: list[str] = []
        for path, desc in candidates:
            if not path.is_file():
                tried.append(f"{desc}: not present")
                continue
            try:
                data = json.loads(path.read_text())
                book = cls(data, desc)
                return book, f"canon rulebook: {desc}"
            except (json.JSONDecodeError, ValueError) as exc:
                tried.append(f"{desc}: invalid ({exc})")
        return None, "canon rulebook UNAVAILABLE — " + "; ".join(tried)


# ---------------------------------------------------------------------------
# lint
# ---------------------------------------------------------------------------


def _is_num(x: Any) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def lint_recipe(recipe: dict[str, Any], *, cuisines: set[str],
                meal_slots: set[str], conversions: dict[str, dict[str, float]] | None,
                allergen_scan: "AllergenScanner", canon: CanonRulebook | None,
                ) -> list[str]:
    """Return the list of lint violations for one RS recipe (empty = pass).

    ``conversions`` is accepted for call compatibility (the corpus-side
    validator passes its table) but is no longer consulted: each scored
    line carries its own cited conversion (conversion_ref + grams).

    `allergen_scan.verify_claim` re-computes each claim's evidence from the
    ingredient tables; a claim whose evidence is missing, contradicted, or
    resting on unresolvable ingredient composition is reported as an
    unchecked claim (the suite strips it and counts it).

    When ``canon`` is None every doneness judgment fails closed.
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
    prov = recipe.get("provenance")
    scale_evidence = isinstance(prov, dict) and bool(prov.get("scale_measurements"))
    for i, line in enumerate(recipe["ingredients"]):
        name = line.get("name", "?") if isinstance(line, dict) else "?"
        qty = line.get("qty") if isinstance(line, dict) else None
        if not isinstance(qty, dict):
            v.append(f"{rid}: R2 ingredient[{i}] {name!r} has no quantity evidence")
            continue
        kind = qty.get("kind")
        grams = qty.get("grams")
        if kind not in ALL_KINDS:
            v.append(f"{rid}: R2 ingredient[{i}] {name!r} qty.kind {kind!r} is not quantity evidence")
        elif kind == "household":
            # the line's own cited conversion IS the evidence: conversion_ref
            # plus the resolved grams carried on the line
            conv_ref = qty.get("conversion_ref")
            if not isinstance(conv_ref, str) or not conv_ref.strip():
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} household measure carries no cited conversion_ref")
            if not _is_num(grams) or grams <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} household measure carries no resolved grams "
                         "(unresolved, not weighed; conversion evidence must be cited on the line)")
            unit = qty.get("unit")
            if not isinstance(unit, str) or not unit:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} household measure missing unit")
            value = qty.get("value")
            if not _is_num(value) or value <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} household measure missing positive value")
        elif kind == "weighed":
            if not _is_num(grams) or grams <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} weighed requires positive grams")
            if not scale_evidence:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} 'weighed' requires a recorded scale "
                         "measurement in provenance (a builder estimate is never weighed)")
        elif kind == "source_grams":
            if not _is_num(grams) or grams <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} source_grams requires positive grams")

    # R3 safety: doneness through the canonical rulebook --------------------
    v.extend(_r3_safety(recipe, rid, allergen_scan, canon))

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
            if not _is_num(t) or not (0 < t <= 240):
                v.append(f"{rid}: R5 step[{i}] timer_min {t!r} is not a real timer (1-240 min)")

    # R6 rights linkage is checked by the suite (rights.py) before lint.
    return v


def _r3_safety(recipe: dict[str, Any], rid: str, allergen_scan: "AllergenScanner",
               canon: CanonRulebook | None) -> list[str]:
    """Every doneness judgment, derived from ingredients, reheat flags and the
    canon rulebook. Fails closed when the canon is unavailable."""
    v: list[str] = []
    steps = [s for s in recipe.get("steps", []) if isinstance(s, dict)]

    # -- derive the REQUIRED class set from the ingredients' actual classes --
    allergen_classes, unknown_names = allergen_scan.classify(recipe)
    required: dict[str, dict[str, float]] = {}

    def require(cls: str) -> None:
        if cls not in RS_SAFETY_CLASSES or canon is None:
            return
        cur = required.setdefault(cls, {"temp_f": canon.class_min_f[cls],
                                        "rest": canon.class_rest_min[cls]})
        cur["temp_f"] = max(cur["temp_f"], canon.class_min_f[cls])
        cur["rest"] = max(cur["rest"], canon.class_rest_min[cls])

    for cls in set(allergen_classes) & set(INGREDIENT_SAFETY_CLASSES):
        require(cls)
    if canon is not None:
        for line in recipe.get("ingredients", []):
            name = line.get("name", "") if isinstance(line, dict) else ""
            for cls in canon.classes_for_name(name):
                require(cls)
        for cls in canon.classes_for_title(recipe.get("title", "")):
            require(cls)

    # -- collect the checks the recipe declares ------------------------------
    checks: list[tuple[int, dict[str, Any]]] = []
    for i, step in enumerate(steps):
        if isinstance(step.get("safety"), dict):
            checks.append((i, step["safety"]))

    # -- fail closed when the canon is unavailable ---------------------------
    safety_signal = bool(required) or any(s.get("reheat") or _REHEAT_TEXT.search(str(s.get("text", "")))
                                          for s in steps) or bool(checks)
    if canon is None:
        if safety_signal:
            v.append(f"{rid}: R3 canon rulebook unavailable — doneness cannot be validated, "
                     "failing closed (no safety judgment may pass without the canon)")
        return v

    # -- every reheat step carries its own 165 F leftovers check -------------
    for i, step in enumerate(steps):
        text = str(step.get("text", ""))
        flagged = bool(step.get("reheat"))
        textual = bool(_REHEAT_TEXT.search(text))
        if textual and not flagged:
            v.append(f"{rid}: R3 step[{i}] describes reheating but carries no reheat flag "
                     "(SCHEMA 3: reheating-leftovers steps are flagged)")
        if flagged:
            chk = step.get("safety")
            if not isinstance(chk, dict):
                v.append(f"{rid}: R3 reheat step[{i}] has no thermometer check of its own "
                         "(leftovers must reach 165 F with a thermometer; an unrelated "
                         "check elsewhere in the recipe does not cover this step)")
            else:
                cls, temp = chk.get("class"), chk.get("temp_f")
                if cls != "leftovers":
                    v.append(f"{rid}: R3 reheat step[{i}] check names class {cls!r}, not "
                             "'leftovers' (reheating leftovers must reach 165 F regardless "
                             "of the product class)")
                elif not (_is_num(temp) and temp >= canon.class_min_f["leftovers"]):
                    v.append(f"{rid}: R3 reheat step[{i}] temp_f {temp!r} is below the "
                             f"leftovers minimum {canon.class_min_f['leftovers']:.0f} F")

    # -- each declared check is itself valid ---------------------------------
    for i, chk in checks:
        cls, temp = chk.get("class"), chk.get("temp_f")
        if cls not in RS_SAFETY_CLASSES or canon is None or cls not in canon.class_min_f:
            v.append(f"{rid}: R3 safety check names unknown class {cls!r} (must name an FSIS class)")
            continue
        if not _is_num(temp):
            v.append(f"{rid}: R3 safety check missing numeric temp_f")
            continue
        if temp < canon.class_min_f[cls]:
            v.append(f"{rid}: R3 safety temp_f {temp} below the FSIS minimum "
                     f"{canon.class_min_f[cls]:.0f} F for {cls}")
        if chk.get("method") != "thermometer":
            v.append(f"{rid}: R3 safety check method must be 'thermometer'")
        source = chk.get("source")
        if not source:
            v.append(f"{rid}: R3 safety check must cite its source (USDA FSIS)")
        elif not canon.source_is_canonical(source):
            v.append(f"{rid}: R3 safety source does not resolve against the canon rulebook "
                     "citations (data/food-safety/rules.json)")
        req_rest = canon.class_rest_min.get(cls, 0)
        if req_rest:
            step = steps[i]
            stated = _stated_rest(step, chk)
            if stated is None:
                v.append(f"{rid}: R3 safety check for {cls} must state the required "
                         f"{req_rest:.0f}-minute rest (USDA FSIS: whole cuts rest at least "
                         "3 minutes before carving or consuming)")

    # -- every REQUIRED class is covered by a check naming it ----------------
    for cls, need in sorted(required.items()):
        covered = any(
            chk.get("class") == cls and _is_num(chk.get("temp_f"))
            and chk["temp_f"] >= need["temp_f"]
            for _, chk in checks
        )
        if not covered:
            v.append(f"{rid}: R3 required doneness class {cls} "
                     f"(minimum {need['temp_f']:.0f} F, rest {need['rest']:.0f} min) has no "
                     "thermometer check naming that class and minimum — checks must cover "
                     "each ingredient's ACTUAL class, not an unrelated one")

    # -- doneness by colour/time alone on animal-protein steps ----------------
    needs_safety = bool(required)
    for i, step in enumerate(steps):
        text = str(step.get("text", ""))
        if (needs_safety and _COLOUR_OR_TIME_DONENESS.search(text)
                and not isinstance(step.get("safety"), dict)):
            v.append(f"{rid}: R3 step[{i}] states doneness by colour/time without a thermometer check")
    return v


def _stated_rest(step: dict[str, Any], chk: dict[str, Any]) -> float | None:
    """The rest the check communicates: from the check dict or the step text."""
    rm = chk.get("rest_minutes")
    if _is_num(rm) and rm > 0:
        return float(rm)
    m = _REST_TEXT.search(str(step.get("text", "")))
    if m:
        return float(m.group(1))
    return None


def lint_corpus(recipes: list[dict[str, Any]], *, cuisines: set[str],
                meal_slots: set[str], conversions: dict[str, dict[str, float]] | None,
                allergen_scan: "AllergenScanner", canon: CanonRulebook | None = None,
                ) -> dict[str, Any]:
    """Lint every recipe; return per-recipe violations and corpus line stats."""
    report: dict[str, Any] = {
        "recipes_with_violations": {},
        "total_lines": 0,
        "resolved_lines": 0,
        "stripped_claims": 0,
        "unchecked_claims": 0,
        "stripped_detail": {},
        "classification_incomplete": {},
        "canon": None if canon is None else canon.source,
        "linter_engine": ("canonical rulebook data (see canon/PROVENANCE.md); "
                          "executable FLFoodSafety linter checks: UNVERIFIED-NATIVE "
                          "(Swift package not present on the scored tree)"),
    }
    for recipe in recipes:
        violations = lint_recipe(
            recipe, cuisines=cuisines, meal_slots=meal_slots,
            conversions=conversions, allergen_scan=allergen_scan, canon=canon,
        )
        if violations:
            report["recipes_with_violations"][recipe["id"]] = violations
        # quantity evidence stats over ALL ingredient lines
        for line in recipe.get("ingredients", []):
            report["total_lines"] += 1
            qty = line.get("qty") if isinstance(line, dict) else None
            if isinstance(qty, dict) and _line_resolves(qty, recipe):
                report["resolved_lines"] += 1
        # allergen classification: unknown composition is surfaced, never silent
        _classes, unknown = allergen_scan.classify(recipe)
        if unknown:
            report["classification_incomplete"][recipe["id"]] = unknown
        # claims: evidence-backed stay; unchecked are stripped and counted
        kept_claims = []
        for claim in recipe.get("claims", []):
            verdict = allergen_scan.verify_claim(recipe, claim)
            if verdict is True:
                kept_claims.append(claim)
            else:
                report["stripped_claims"] += 1
                report["unchecked_claims"] += 1
                report["stripped_detail"].setdefault(recipe["id"], []).append(
                    {"claim": claim.get("claim"), "reason": str(verdict)})
        recipe["claims"] = kept_claims
    report["passed"] = [
        r["id"] for r in recipes if r["id"] not in report["recipes_with_violations"]
    ]
    return report


def _line_resolves(qty: dict[str, Any], recipe: dict[str, Any]) -> bool:
    """A line resolves to grams only when its OWN carried evidence supports it.

    - source_grams: positive grams;
    - household: a cited conversion (conversion_ref) AND positive grams on
      the line;
    - weighed: positive grams AND a recorded scale measurement in provenance
      (a builder estimate is never weighed).
    """
    kind = qty.get("kind")
    grams = qty.get("grams")
    if not _is_num(grams) or grams <= 0:
        return False
    if kind == "source_grams":
        return True
    if kind == "household":
        ref = qty.get("conversion_ref")
        return isinstance(ref, str) and bool(ref.strip())
    if kind == "weighed":
        prov = recipe.get("provenance")
        return isinstance(prov, dict) and bool(prov.get("scale_measurements"))
    return False


# ---------------------------------------------------------------------------
# allergen / diet claims: the scanner is the only evidence source
# ---------------------------------------------------------------------------


class AllergenScanner:
    """Verify allergen/diet claims by scanning ingredient classes.

    Evidence is recomputed here from the interim alias table
    (`allergens.json`). An ingredient whose composition no table resolves
    makes the recipe's classification INCOMPLETE and every claim on it
    UNCHECKED — unknown composition never means allowed. When the
    FLIngredientFacts package (one ``evaluate()`` whose unknown result never
    means allowed) lands, this class becomes its thin consumer: the same
    fail-closed contract, sourced composition instead of an alias table.
    """

    def __init__(self, table: dict[str, Any]) -> None:
        self.table = table
        self.claim_defs: dict[str, dict[str, Any]] = table["claims"]

    def classify(self, recipe: dict[str, Any]) -> tuple[set[str], list[str]]:
        """Allergen classes for a recipe's ingredients, plus the names whose
        composition is UNRESOLVED (never silently treated as allowed)."""
        classes: set[str] = set()
        unknown: list[str] = []
        for line in recipe.get("ingredients", []):
            name = str(line.get("name", "")).strip().lower() if isinstance(line, dict) else ""
            if not name:
                continue
            key = self.table["ingredient_aliases"].get(name)
            if key and key in self.table["ingredients"]:
                classes |= set(self.table["ingredients"][key].get("classes", []))
            else:
                unknown.append(name)
        return classes, unknown

    def classes_for(self, recipe: dict[str, Any]) -> set[str]:
        """Resolved allergen classes only (compat: unresolvable names are
        NOT classes here — use classify() to see them)."""
        return self.classify(recipe)[0]

    def verify_claim(self, recipe: dict[str, Any], claim: dict[str, Any]) -> Any:
        """True when the claim is backed by a matching recomputed scan;
        a human-readable reason string when it is unchecked."""
        cname = claim.get("claim")
        if cname not in self.claim_defs:
            return f"unknown claim type {cname!r}"
        if not isinstance(claim.get("evidence"), dict):
            return "claim carries no evidence field"
        _classes, unknown = self.classify(recipe)
        if unknown:
            return (f"ingredient composition unresolved for {unknown} "
                    "(classification INCOMPLETE; unknown never means allowed)")
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
