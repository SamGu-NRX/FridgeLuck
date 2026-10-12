"""RS — the recipes-grammar format for the FridgeLuck corpus, and its linter.

RS is the structured recipe schema suite C validates against. It encodes the
SPEC 3.5 rule "structured or not shipped":

- ingredient lines carry quantity evidence: ``weighed`` (a recorded scale
  measurement in provenance, LINKED to that line — a builder estimate is
  never weighed, and a recipe-level flag clears nothing), ``source_grams``,
  ``household`` (a household measure whose line carries its own cited
  conversion: ``conversion_ref`` plus the resolved ``grams``), or
  ``unknown`` — never an invented mass. Every citation must RESOLVE from
  the corpus record itself (the record's own conversion-evidence rows or
  the corpus-owned ``data/recipes/conversions.json`` on the scored tree —
  never a harness-internal lookup table): the cited reference must exist
  AND cover that line. An unresolvable conversion_ref is a violation and
  an unresolved line, not weighed;
- steps split at timer and action boundaries where real: a ``timer_min`` only
  where the step has a natural one;
- doneness for meat, poultry, fish, eggs and leftovers is a thermometer check
  derived from each ingredient's ACTUAL class through the canonical
  food-safety rulebook (`data/food-safety/rules.json`, branch
  overhaul/food-safety-canon), never colour or time alone. Every required
  class must be covered at or above the class minimum, every check must be
  cook-visible (the step text itself names a thermometer reading of the class
  minimum), whole cuts must state the required 3-minute rest, an ingredient
  whose class cannot be established fails closed, and every reheat step must
  carry its own 165 F ``leftovers`` check;
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
  fails closed: every recipe is a violation, because its ingredient
  classification is unresolved. An INVALID present rules.json fails closed
  naming the invalid source — it never falls back to the pinned snapshot.
  The linter never substitutes its own temperature table.
- Ingredient composition for allergen/diet claim verdicts comes ONLY from
  FLIngredientFacts data (``data/ingredient-facts``, branch
  overhaul/ingredient-facts — PR #127; loaded scored-tree-first, else the
  pinned snapshot in ``canon/ingredient-facts/``). When the facts source is
  absent, or an ingredient has no identity or no facts row, or the claim's
  axes are unknown, every dependent claim is HELD — counted unchecked with a
  reason naming the absent or incomplete source; never cleared, never
  silently skipped. The suite's interim alias table (``allergens.json``)
  no longer clears claims: it only feeds R3 doneness classification.
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

# Cook-visible doneness (PR #88 r3 review BLOCK 1): the instruction text
# itself must name thermometer language AND an internal-temperature reading
# of the class minimum — the safety metadata alone never tells the cook what
# internal temperature to look for.
_THERMOMETER_TEXT = re.compile(
    r"\bthermometer\b|\binstant-read\b|\btemperature probe\b|\binternal temperature\b",
    re.IGNORECASE)
_TEXT_TEMP_F = re.compile(r"(\d{2,3})\s*(?:°\s*)?F\b|(\d{2,3})\s*degrees\b",
                          re.IGNORECASE)

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
        (``canon/rules.json``, see canon/PROVENANCE.md). The snapshot is
        used only when the scored tree carries NO rulebook: an INVALID
        present file fails closed — (None, a reason naming the invalid
        source) — it never falls back. Callers must fail closed on None.
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
                # An INVALID present rulebook fails closed — it never falls
                # back to a lower-precedence source (BLOCK 2: the snapshot
                # fallback hid an invalid canonical input).
                return None, (f"canon rulebook INVALID — {desc}: invalid ({exc}); "
                              "failing closed, no fallback")
        return None, "canon rulebook UNAVAILABLE — " + "; ".join(tried)


# ---------------------------------------------------------------------------
# lint
# ---------------------------------------------------------------------------


def _is_num(x: Any) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


# ---------------------------------------------------------------------------
# quantity evidence: resolution from the corpus record itself
# ---------------------------------------------------------------------------
# A line's citation is not its own evidence. Each conversion_ref must resolve
# to a conversion-evidence row the CORPUS supplies — the record's own rows
# (record["conversions"] or provenance.conversions) or the corpus-owned
# data/recipes/conversions.json on the scored tree — and that row must cover
# the line it clears. The suite's fixture table is never consulted here.


def _norm_name(s: Any) -> str:
    return " ".join(str(s).split()).lower()


def as_conversion_rows(value: Any) -> dict[str, dict[str, Any]]:
    """Normalize a corpus-supplied conversion-evidence payload to ref -> row.

    Accepts a mapping ref -> row, ``{"conversions": <mapping or list>}``, or
    a list of rows each naming its ref (``ref`` or ``id``). Boundary parsing
    for everything the corpus may ship; callers downstream get one shape.
    """
    if value is None:
        return {}
    if isinstance(value, dict):
        rows = value.get("conversions", value)
    else:
        rows = value
    out: dict[str, dict[str, Any]] = {}
    if isinstance(rows, dict):
        items: list[tuple[Any, Any]] = list(rows.items())
    elif isinstance(rows, list):
        items = [(r.get("ref") or r.get("id"), r) for r in rows
                 if isinstance(r, dict)]
    else:
        return out
    for ref, row in items:
        if isinstance(ref, str) and ref.strip() and isinstance(row, dict):
            out[ref.strip()] = row
    return out


def record_conversion_rows(recipe: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """The conversion-evidence rows the corpus RECORD itself carries.

    Accepted on the record: ``recipe["conversions"]`` or
    ``recipe["provenance"]["conversions"]`` — a mapping ref -> row or a
    list of rows each naming its ref. This is the record's OWN evidence;
    a row here must still cover the line it clears.
    """
    rows: Any = recipe.get("conversions")
    if rows is None:
        prov = recipe.get("provenance")
        rows = prov.get("conversions") if isinstance(prov, dict) else None
    return as_conversion_rows(rows)


def _row_covers(row: dict[str, Any], qty: dict[str, Any], name: str) -> bool:
    """True when a conversion row actually covers THIS line: the row names
    the line's ingredient (``ingredient``/``covers``), and a declared unit
    matches the line's unit. A real row covering a different line never
    resolves this one."""
    covers: Any = row.get("ingredient", row.get("covers"))
    if isinstance(covers, str):
        covers = [covers]
    covered = {_norm_name(c) for c in covers} if isinstance(covers, list) else set()
    if _norm_name(name) not in covered:
        return False
    row_unit = row.get("unit")
    if isinstance(row_unit, str) and row_unit and row_unit != qty.get("unit"):
        return False
    return True


def _conversion_row_for(qty: dict[str, Any], name: str, recipe: dict[str, Any],
                        corpus_rows: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    """The conversion row that resolves this line's citation AND covers it,
    or None. Record-carried rows take precedence over corpus-level rows;
    either way the row must exist, carry a positive ``grams_per_unit``, and
    cover this line."""
    ref = qty.get("conversion_ref")
    if not (isinstance(ref, str) and ref.strip()):
        return None
    merged = {**corpus_rows, **record_conversion_rows(recipe)}
    row = merged.get(ref.strip())
    if not isinstance(row, dict):
        return None
    gpu = row.get("grams_per_unit")
    if not _is_num(gpu) or gpu <= 0:
        return None
    return row if _row_covers(row, qty, name) else None


def _scale_row_for(prov: Any, index: int, name: str) -> dict[str, Any] | None:
    """The recorded scale measurement linked to THIS line, or None.

    ``provenance.scale_measurements`` must be a list of per-line rows, each
    linked to its line by ``ingredient`` (the line's name) or ``line`` (the
    ingredient's index). A recipe-level flag, a bare ``true``, or a
    measurement of a different line is not evidence for this one.
    """
    if not isinstance(prov, dict):
        return None
    rows = prov.get("scale_measurements")
    if not isinstance(rows, list):
        return None
    for row in rows:
        if not isinstance(row, dict):
            continue
        by_index = row.get("line")
        if isinstance(by_index, int) and not isinstance(by_index, bool):
            if by_index == index:
                return row
            continue  # linked to a different line
        if "ingredient" in row:
            if _norm_name(row.get("ingredient")) == _norm_name(name):
                return row
            continue
        # linked to no line at all: evidence for nothing
    return None


def _grams_agree(carried: Any, expected: Any) -> bool:
    """The line's carried grams agree with what its evidence supports
    (rounding slack: 1 g or 2%, whichever is larger). A disagreement means
    the carried mass is not the one the cited evidence supports."""
    return (_is_num(carried) and _is_num(expected)
            and abs(float(carried) - float(expected)) <= max(1.0, 0.02 * float(expected)))


def lint_recipe(recipe: dict[str, Any], *, cuisines: set[str],
                meal_slots: set[str], conversion_rows: dict[str, dict[str, Any]] | None,
                allergen_scan: "AllergenScanner", canon: CanonRulebook | None,
                ) -> list[str]:
    """Return the list of lint violations for one RS recipe (empty = pass).

    ``conversion_rows`` is the corpus's OWN conversion-evidence rows
    (ref -> row, from the scored tree's ``data/recipes/conversions.json``);
    the record's own carried rows take precedence. A line's citation must
    resolve there AND cover that line — a nonempty ``conversion_ref``
    string plus positive grams clears nothing by itself.

    `allergen_scan.verify_claim` re-computes each claim's evidence from
    FLIngredientFacts composition; a claim whose evidence is missing,
    contradicted, or resting on unknown or missing composition is reported
    as an unchecked claim (the suite strips it and counts it).

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
    # Resolution source: the corpus record's own conversion-evidence rows
    # (record-carried rows over corpus-level rows). A citation that resolves
    # nowhere is a violation naming the absent evidence, and the line counts
    # as unresolved (see _line_resolves).
    prov = recipe.get("provenance")
    corpus_rows = as_conversion_rows(conversion_rows)
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
            conv_ref = qty.get("conversion_ref")
            unit = qty.get("unit")
            value = qty.get("value")
            cited = isinstance(conv_ref, str) and bool(conv_ref.strip())
            # the line's own cited conversion IS the evidence: conversion_ref
            # plus the resolved grams carried on the line
            if not cited:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} household measure carries no cited conversion_ref")
            if not _is_num(grams) or grams <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} household measure carries no resolved grams "
                         "(unresolved, not weighed; conversion evidence must be cited on the line)")
            if not isinstance(unit, str) or not unit:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} household measure missing unit")
            if not _is_num(value) or value <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} household measure missing positive value")
            # the citation must RESOLVE in the record's own rows and cover
            # this line — a nonempty string alone clears nothing
            if cited and _is_num(grams) and grams > 0 and _is_num(value) and value > 0:
                row = _conversion_row_for(qty, name, recipe, corpus_rows)
                if row is None:
                    v.append(f"{rid}: R2 ingredient[{i}] {name!r} cites conversion_ref "
                             f"{conv_ref.strip()!r}, which does not resolve to a covering row in the "
                             "corpus record's conversion-evidence rows (record-carried rows or the "
                             "corpus's data/recipes/conversions.json); the cited reference must "
                             "exist AND cover this line — an invented reference resolves nothing")
                elif not _grams_agree(grams, value * row["grams_per_unit"]):
                    v.append(f"{rid}: R2 ingredient[{i}] {name!r} carries grams {grams}, which "
                             f"disagrees with its cited conversion {conv_ref.strip()!r} "
                             f"({value} x {row['grams_per_unit']} g/unit) — the carried mass is "
                             "not the one the cited evidence supports")
        elif kind == "weighed":
            if not _is_num(grams) or grams <= 0:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} weighed requires positive grams")
            # per-line linkage: a measurement linked to THIS line, not a
            # recipe-level flag or a measurement of some other line
            row = _scale_row_for(prov, i, name)
            if row is None:
                v.append(f"{rid}: R2 ingredient[{i}] {name!r} 'weighed' requires a recorded scale "
                         "measurement in provenance LINKED TO THIS LINE (a recipe-level flag "
                         "alone clears nothing, and a measurement of another line covers "
                         "nothing here; a builder estimate is never weighed)")
            elif _is_num(grams) and grams > 0:
                recorded = row.get("grams")
                if not _is_num(recorded) or recorded <= 0:
                    v.append(f"{rid}: R2 ingredient[{i}] {name!r} has a linked scale measurement "
                             "that records no positive grams")
                elif not _grams_agree(grams, recorded):
                    v.append(f"{rid}: R2 ingredient[{i}] {name!r} carries grams {grams}, which "
                             f"disagrees with its linked scale measurement {recorded}")
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
        # a reheat step pulls the reheat class itself: leftovers must reach
        # 165 F whatever product class the food belonged to before chilling
        for s in steps:
            if s.get("reheat"):
                require("leftovers")
        # unresolved classification fails closed (BLOCK 2): an ingredient the
        # canon cannot classify and the allergen table does not know (e.g.
        # venison) is an animal protein we cannot judge — never silently safe
        unresolved = sorted({n for n in unknown_names if not canon.classes_for_name(n)})
        if unresolved:
            v.append(f"{rid}: R3 unresolved safety classification for ingredient(s) "
                     f"{', '.join(repr(n) for n in unresolved[:6])}: no canon doneness "
                     "class and no allergen-table entry — an ingredient whose protein "
                     "class cannot be established never passes safety lint")

    # -- collect the checks the recipe declares ------------------------------
    checks: list[tuple[int, dict[str, Any]]] = []
    for i, step in enumerate(steps):
        if isinstance(step.get("safety"), dict):
            checks.append((i, step["safety"]))

    # -- fail closed when the canon is unavailable ---------------------------
    # Unresolved safety classification (BLOCK 2): without the canonical
    # rulebook no ingredient's doneness class can be established and no class
    # minimum exists to check against — every recipe fails closed naming its
    # ingredients. (A chicken recipe with no safety metadata used to escape
    # here because `required` stayed empty and no other signal existed.)
    if canon is None:
        names = sorted({str(line.get("name", "")).strip().lower()
                        for line in recipe.get("ingredients", [])
                        if isinstance(line, dict) and str(line.get("name", "")).strip()})
        shown = ", ".join(repr(n) for n in names[:6]) or "(no named ingredients)"
        v.append(f"{rid}: R3 canon rulebook unavailable — unresolved safety classification "
                 f"for ingredient(s) {shown}: doneness classes and class minimums come "
                 "only from the canonical rulebook data/food-safety/rules.json, "
                 "failing closed")
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
        # cook-visible reading (BLOCK 1): the step text itself must name a
        # thermometer reading of the class minimum — metadata alone never
        # told the cook what internal temperature to look for
        step = steps[i]
        reading = _text_internal_reading_f(str(step.get("text", "")))
        if reading is None or reading < canon.class_min_f[cls]:
            v.append(f"{rid}: R3 step[{i}] check for {cls} is not cook-visible: the "
                     "instruction text must name a thermometer reading of at least the "
                     f"{cls} minimum {canon.class_min_f[cls]:.0f} F (the safety metadata "
                     "alone never tells the cook the internal temperature to look for)")
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
            stated = _stated_rest(step, chk)
            if stated is None:
                v.append(f"{rid}: R3 safety check for {cls} must state the required "
                         f"{req_rest:.0f}-minute rest (USDA FSIS: whole cuts rest at least "
                         "3 minutes before carving or consuming)")
            elif stated < req_rest:
                v.append(f"{rid}: R3 safety check for {cls} states a {stated:.0f}-minute "
                         f"rest, below the required {req_rest:.0f}-minute minimum "
                         "(USDA FSIS: whole cuts rest at least 3 minutes before carving "
                         "or consuming)")

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


def _text_internal_reading_f(text: str) -> float | None:
    """The cook-visible internal reading: the highest temperature (°F) named
    in a sentence that also names thermometer language. None when no sentence
    pairs the two (an oven number in a sentence without thermometer language
    is not an internal reading)."""
    for sentence in re.split(r"[.;\n]", text):
        if not _THERMOMETER_TEXT.search(sentence):
            continue
        temps = [float(m.group(1) or m.group(2))
                 for m in _TEXT_TEMP_F.finditer(sentence)]
        if temps:
            return max(temps)
    return None


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
                meal_slots: set[str], conversion_rows: dict[str, dict[str, Any]] | None,
                allergen_scan: "AllergenScanner", canon: CanonRulebook | None = None,
                ) -> dict[str, Any]:
    """Lint every recipe; return per-recipe violations and corpus line stats.

    ``conversion_rows``: the corpus's OWN conversion-evidence rows
    (ref -> row) from the scored tree — never a harness-internal table.
    """
    corpus_rows = as_conversion_rows(conversion_rows)
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
            conversion_rows=conversion_rows, allergen_scan=allergen_scan, canon=canon,
        )
        if violations:
            report["recipes_with_violations"][recipe["id"]] = violations
        # quantity evidence stats over ALL ingredient lines
        for i, line in enumerate(recipe.get("ingredients", [])):
            report["total_lines"] += 1
            qty = line.get("qty") if isinstance(line, dict) else None
            if isinstance(qty, dict) and _line_resolves(qty, i, recipe, corpus_rows):
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


def _line_resolves(qty: dict[str, Any], index: int, recipe: dict[str, Any],
                   corpus_rows: dict[str, dict[str, Any]]) -> bool:
    """A line resolves to grams only when its OWN carried evidence supports
    it, RESOLVED from the corpus record itself (the record's own
    conversion-evidence rows over the corpus's data/recipes rows — never a
    harness-internal lookup table):

    - source_grams: positive grams;
    - household: a cited conversion that RESOLVES to a row in the record's
      (or corpus's) conversion-evidence rows, that row COVERS this line,
      and positive grams on the line agreeing with the cited conversion;
    - weighed: positive grams AND a scale measurement linked to THIS line
      in provenance agreeing with the line's grams (a builder estimate is
      never weighed; a recipe-level flag clears nothing).

    Honest ``unknown`` stays allowed and counts as unresolved.
    """
    grams = qty.get("grams")
    if not _is_num(grams) or grams <= 0:
        return False
    kind = qty.get("kind")
    if kind == "source_grams":
        return True
    lines = recipe.get("ingredients")
    name = ""
    if isinstance(lines, list) and 0 <= index < len(lines) and isinstance(lines[index], dict):
        name = str(lines[index].get("name", ""))
    if kind == "household":
        row = _conversion_row_for(qty, name, recipe, corpus_rows)
        if row is None:
            return False
        value = qty.get("value")
        return (_is_num(value) and value > 0
                and _grams_agree(grams, value * row["grams_per_unit"]))
    if kind == "weighed":
        row = _scale_row_for(recipe.get("provenance"), index, name)
        if row is None:
            return False
        recorded = row.get("grams")
        return _is_num(recorded) and recorded > 0 and _grams_agree(grams, recorded)
    return False


# ---------------------------------------------------------------------------
# allergen / diet claims: FLIngredientFacts is the only evidence source
# ---------------------------------------------------------------------------


# Canonical facts dataset provenance (canon/ingredient-facts/PROVENANCE.md):
# the head of branch overhaul/ingredient-facts the snapshot was pinned from.
PINNED_FACTS_HEAD = "b0deecce36bf6ee91e6f5933e746d75466165288"
CANON_FACTS_DIR = Path(__file__).resolve().parent / "canon" / "ingredient-facts"

# Corpus claim type -> FLIngredientFacts axes that must be free/allowed for
# the claim to clear (data/ingredient-facts/README.md: nine FDA allergens,
# the separate gluten property, five diets).
CLAIM_AXES: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "gluten-free": ((), ("glutenFree",)),
    "dairy-free": (("milk",), ()),
    "nut-free": (("treeNuts", "peanuts"), ()),
    "vegetarian": ((), ("vegetarian",)),
    "vegan": ((), ("vegan",)),
}
# The gluten property is its own axis (never merged with wheat): a gluten-free
# claim is contradicted by gluten 'contains' and undecided while gluten is
# 'unknown'. A gluten-free label never settles wheat (FDA 21 CFR 101.100), so
# wheat stays out of claim verdicts.
GLUTEN_PROPERTY_CLAIMS = ("gluten-free",)


class FLIngredientFacts:
    """The validated FLIngredientFacts dataset behind every claim verdict.

    A thin, read-only consumer of the canonical dataset
    ``data/ingredient-facts`` (branch ``overhaul/ingredient-facts``, PR
    #127): identities resolve an ingredient line name (key, display,
    synonym, or product form) to a facts row; facts rows carry allergen,
    diet and gluten states with evidence. Load-time validation mirrors the
    dataset's own conformance runner so all consumers reject the same
    malformed data.
    """

    ALLERGENS = ("milk", "egg", "fish", "crustaceanShellfish", "treeNuts",
                 "peanuts", "wheat", "soy", "sesame")
    DIETS = ("vegetarian", "vegan", "pescatarian", "glutenFree", "dairyFree")
    EVIDENCE_KINDS = ("usda", "label", "reference", "recipe", "standard")
    FACT_STATES = ("contains", "free", "unknown", "allowed", "violated")
    CERTAINTIES = ("certain", "typical", "variable", "unknown")

    def __init__(self, identities: dict[str, Any], facts: dict[str, Any],
                 source: str) -> None:
        self.source = source
        if identities.get("version") != 1 or facts.get("version") != 1:
            raise ValueError("FLIngredientFacts dataset version must be 1")
        rows = identities.get("ingredients")
        if not isinstance(rows, list) or not rows:
            raise ValueError("identities.json carries no ingredients")
        self.facts: dict[str, dict[str, Any]] = facts.get("facts", {})
        if not self.facts:
            raise ValueError("facts.json carries no facts")
        self._name_index: dict[str, str] = {}
        self._form_index: dict[str, tuple[str, str]] = {}
        self._validate(rows)

    # -- validation (mirrors the dataset conformance runner) ----------------

    def _index_name(self, raw: str, key: str) -> None:
        name = raw.strip().lower()
        existing = self._name_index.get(name)
        if existing is not None and existing != key:
            raise ValueError(f"name {raw!r} maps to both {existing} and {key}")
        self._name_index[name] = key

    def _index_form_name(self, raw: str, identity: str, form: str) -> None:
        name = raw.strip().lower()
        if name in self._form_index or name in self._name_index:
            raise ValueError(f"match name {raw!r} is not unique "
                             f"(identity {identity}, form {form})")
        self._form_index[name] = (identity, form)
        self._name_index[name] = identity

    def _check_evidence(self, evidence: Any, where: str) -> None:
        if not isinstance(evidence, dict):
            raise ValueError(f"{where}: fact lacks evidence")
        if evidence.get("kind") not in self.EVIDENCE_KINDS:
            raise ValueError(f"{where}: bad evidence kind {evidence.get('kind')!r}")
        for field in ("ref", "note"):
            value = evidence.get(field)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{where}: evidence {field} must be a non-empty string")

    def _check_axis(self, fact: Any, where: str) -> None:
        if not isinstance(fact, dict):
            raise ValueError(f"{where}: malformed fact")
        state = fact.get("state")
        if state not in self.FACT_STATES:
            raise ValueError(f"{where}: bad state {state!r}")
        if state == "unknown" and fact.get("evidence") is None:
            return
        self._check_evidence(fact.get("evidence"), where)
        if state in ("free", "allowed") and fact["evidence"].get("kind") in ("usda", "recipe"):
            raise ValueError(f"{where}: absence state {state!r} may not use "
                             "catalog/recipe evidence (absence never rests on them)")

    def _validate_entry(self, entry: dict[str, Any], *, where: str) -> None:
        for axis, fact in (entry.get("allergens") or {}).items():
            if axis not in self.ALLERGENS:
                raise ValueError(f"{where}: unknown allergen {axis!r}")
            self._check_axis(fact, f"{where}.allergens.{axis}")
        for axis, fact in (entry.get("diets") or {}).items():
            if axis not in self.DIETS:
                raise ValueError(f"{where}: unknown diet {axis!r}")
            self._check_axis(fact, f"{where}.diets.{axis}")
        if entry.get("gluten"):
            self._check_axis(entry["gluten"], f"{where}.gluten")
        for form_key, override in (entry.get("forms") or {}).items():
            self._validate_entry(override, where=f"{where}.forms.{form_key}")
        for component in entry.get("components") or []:
            comp_key = component.get("key")
            if comp_key not in self.facts:
                raise ValueError(f"{where}: component key {comp_key!r} does not resolve")
            if component.get("certainty") not in self.CERTAINTIES:
                raise ValueError(f"{where}: component {comp_key!r} has bad certainty")
            if component.get("certainty") != "unknown":
                self._check_evidence(component.get("evidence"),
                                     f"{where}.components.{comp_key}")

    def _validate(self, rows: list[Any]) -> None:
        keys: set[str] = set()
        for row in rows:
            key = row.get("key") if isinstance(row, dict) else None
            if not key:
                raise ValueError("identity row without a key")
            if key in keys:
                raise ValueError(f"duplicate identity key {key!r}")
            keys.add(key)
            self._index_name(str(key), str(key))
            display = row.get("display")
            if isinstance(display, str) and display:
                self._index_name(display, str(key))
            for syn in row.get("synonyms") or []:
                self._index_name(str(syn), str(key))
            entry = self.facts.get(str(key))
            for form in row.get("forms") or []:
                form_key = str(form.get("key") or "")
                if not form_key:
                    raise ValueError(f"identity {key!r}: form without a key")
                for syn in form.get("synonyms") or []:
                    self._index_form_name(str(syn), str(key), form_key)
                override = (entry or {}).get("forms", {}).get(form_key)
                if not isinstance(override, dict):
                    raise ValueError(f"identity {key!r} form {form_key!r} "
                                     "has no fact override")
            if entry is None:
                # A resolvable identity without a facts row stays loadable:
                # verdicts on it FAIL CLOSED per ingredient (verify_claim),
                # the same direction the dataset demonstrates with its own
                # 'artisan-granola-bar' fail-closed case.
                continue
            self._validate_entry(entry, where=str(key))
        for fkey, entry in self.facts.items():
            if entry.get("key") != fkey:
                raise ValueError(f"fact entry key mismatch: {fkey!r} vs {entry.get('key')!r}")

    # -- lookups ------------------------------------------------------------

    def resolve(self, name: str) -> tuple[str, str | None] | None:
        """(identity key, form key) for one ingredient line name, or None."""
        folded = str(name).strip().lower()
        key = self._name_index.get(folded)
        if key is None:
            return None
        form = self._form_index.get(folded)
        return (key, form[1] if form else None)

    def entry(self, key: str) -> dict[str, Any] | None:
        """The facts row for one identity key (None when the row is absent)."""
        return self.facts.get(key)

    # -- loading ------------------------------------------------------------

    @classmethod
    def load(cls, repo_root: Path | None = None,
             ) -> tuple["FLIngredientFacts | None", str]:
        """Load the facts dataset; returns (store, provenance) or (None, reason).

        Precedence: the scored tree's ``data/ingredient-facts/`` when
        ``repo_root`` carries one, else the suite-pinned snapshot
        (``canon/ingredient-facts/``, see canon/ingredient-facts/PROVENANCE.md).
        Any parse or validation failure returns (None, reason) — callers fail
        closed and every claim is held with this reason.
        """
        candidates: list[tuple[Path, str]] = []
        if repo_root is not None:
            candidates.append((Path(repo_root) / "data" / "ingredient-facts",
                               "scored tree data/ingredient-facts"))
        candidates.append((CANON_FACTS_DIR,
                           f"suite-pinned snapshot canon/ingredient-facts "
                           f"(overhaul/ingredient-facts @ {PINNED_FACTS_HEAD[:12]})"))
        tried: list[str] = []
        for data_dir, desc in candidates:
            ids_path = data_dir / "identities.json"
            facts_path = data_dir / "facts.json"
            if not (ids_path.is_file() and facts_path.is_file()):
                tried.append(f"{desc}: not present")
                continue
            try:
                store = cls(json.loads(ids_path.read_text()),
                            json.loads(facts_path.read_text()), desc)
                return store, f"FLIngredientFacts: {desc}"
            except (json.JSONDecodeError, ValueError, OSError) as exc:
                tried.append(f"{desc}: invalid ({exc})")
        return None, ("FLIngredientFacts unavailable (canonical source: branch "
                      "overhaul/ingredient-facts, PR #127); tried: "
                      + "; ".join(tried))


def _axis_fact(entry: dict[str, Any], form: str | None, kind: str,
               axis: str) -> dict[str, Any] | None:
    """One axis fact for an ingredient: the product-form override when the
    line names a form, else the base entry (per-axes merge, as the dataset's
    conformance runner resolves)."""
    if form:
        override = (entry.get("forms") or {}).get(form)
        if isinstance(override, dict):
            fact = (override.get(f"{kind}s") or {}).get(axis)
            if fact is not None:
                return fact
    return (entry.get(f"{kind}s") or {}).get(axis)


def _gluten_fact(entry: dict[str, Any], form: str | None) -> dict[str, Any] | None:
    """The gluten property fact (separate axis), form override first."""
    if form:
        override = (entry.get("forms") or {}).get(form)
        if isinstance(override, dict) and override.get("gluten") is not None:
            return override["gluten"]
    return entry.get("gluten")


def _claim_axis_verdicts(entry: dict[str, Any] | None, form: str | None,
                         claim_name: str, line_name: str, key: str | None,
                         ) -> tuple[list[str], list[str]]:
    """Pure: one ingredient's facts row against one claim's axes.

    Returns (conflict labels, hold reasons). Conflicts are fact states that
    contradict the claim ('contains'/'violated'); holds are undecided
    compositions (no facts row, unknown or absent axis state). Unknown
    composition never means allowed.
    """
    conflicts: list[str] = []
    holds: list[str] = []
    where = (f"ingredient {line_name!r} (FLIngredientFacts {key!r})"
             if key else f"ingredient {line_name!r}")
    if entry is None:
        holds.append(f"{where}: no facts row — source incomplete, fail closed")
        return conflicts, holds
    allergens, diets = CLAIM_AXES[claim_name]
    for axis in allergens:
        fact = _axis_fact(entry, form, "allergen", axis)
        state = fact.get("state") if isinstance(fact, dict) else None
        if state == "contains":
            conflicts.append(f"allergen:{axis}")
        elif state != "free":
            holds.append(f"{where}: allergen {axis!r} state missing or unknown "
                         "— held (unknown composition never means allowed)")
    for axis in diets:
        fact = _axis_fact(entry, form, "diet", axis)
        state = fact.get("state") if isinstance(fact, dict) else None
        if state == "violated":
            conflicts.append(f"diet:{axis}")
        elif state != "allowed":
            holds.append(f"{where}: diet {axis!r} state missing or unknown "
                         "— held (unknown composition never means allowed)")
    if claim_name in GLUTEN_PROPERTY_CLAIMS:
        fact = _gluten_fact(entry, form)
        state = fact.get("state") if isinstance(fact, dict) else None
        if state == "contains":
            conflicts.append("gluten")
        elif state == "unknown":
            holds.append(f"{where}: gluten property unknown "
                         "— held (unknown composition never means allowed)")
        # 'free' clears only together with the diet axis above; an absent
        # gluten property leaves the decision to the diet axis.
    return conflicts, holds


class AllergenScanner:
    """Verify allergen/diet claims against FLIngredientFacts — thin consumer.

    Verdicts come ONLY from the FLIngredientFacts dataset (loaded
    scored-tree-first, else the pinned snapshot ``canon/ingredient-facts/``):
    a claim clears only when every ingredient resolves to a facts row whose
    claim-relevant axes are free/allowed with valid evidence and the
    recomputed conflicts match the recorded evidence. When the facts source
    is absent, or an ingredient has no identity or no facts row, or its
    composition is unknown, every dependent claim is HELD — unchecked, with
    a reason naming the absent or incomplete source. Unknown composition
    never means allowed, and the fixture alias table (``allergens.json``)
    never clears a claim: it only feeds R3 doneness classification.
    """

    def __init__(self, table: dict[str, Any],
                 facts: "FLIngredientFacts | None" = None,
                 facts_reason: str | None = None) -> None:
        self.table = table
        self.claim_defs: dict[str, dict[str, Any]] = table["claims"]
        if facts is None and facts_reason is None:
            self.facts, self.facts_reason = FLIngredientFacts.load()
        else:
            self.facts, self.facts_reason = facts, facts_reason

    def ingredient_verdicts(self, recipe: dict[str, Any], claim_name: str,
                            ) -> tuple[list[str], list[str], list[str]]:
        """Per-ingredient verdicts for one claim type: (conflict labels,
        conflicting ingredient names, hold reasons)."""
        conflicts: list[str] = []
        conflicted_names: list[str] = []
        holds: list[str] = []
        for line in recipe.get("ingredients", []):
            name = str(line.get("name", "")).strip() if isinstance(line, dict) else ""
            if not name:
                continue
            if self.facts is None:
                holds.append(f"ingredient {name!r}: {self.facts_reason}")
                continue
            resolved = self.facts.resolve(name)
            if resolved is None:
                holds.append(f"ingredient {name!r}: no FLIngredientFacts identity "
                             "(unknown name — composition unknown, fail closed)")
                continue
            key, form = resolved
            entry = self.facts.entry(key)
            line_conflicts, line_holds = _claim_axis_verdicts(
                entry, form, claim_name, name, key)
            if line_conflicts:
                conflicted_names.append(name)
            conflicts.extend(line_conflicts)
            holds.extend(line_holds)
        return conflicts, conflicted_names, holds

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
        """True when FLIngredientFacts composition backs the claim; a
        human-readable reason string when it is HELD (unchecked)."""
        cname = claim.get("claim")
        if cname not in self.claim_defs:
            return f"unknown claim type {cname!r}"
        if not isinstance(claim.get("evidence"), dict):
            return "claim carries no evidence field"
        if cname not in CLAIM_AXES:
            return (f"claim type {cname!r} maps to no FLIngredientFacts axes "
                    "— held (fail closed: no composition path clears this claim)")
        if self.facts is None:
            return ("FLIngredientFacts unavailable (canonical source: branch "
                    "overhaul/ingredient-facts, PR #127) — "
                    f"{self.facts_reason}: claim HELD (fail closed — verdicts "
                    "come only from FLIngredientFacts, never the fixture alias "
                    "table; unknown composition never means allowed)")
        conflicts, conflicted_names, holds = self.ingredient_verdicts(recipe, cname)
        if holds:
            return ("; ".join(holds) + " — claim HELD (fail closed; source: "
                    f"{self.facts.source})")
        recorded = set(claim["evidence"].get("conflicts", []))
        if sorted(conflicts) != sorted(recorded):
            return (f"evidence disagrees with FLIngredientFacts-recomputed "
                    f"conflicts (recorded {sorted(recorded)}, recomputed "
                    f"{sorted(conflicts)}; offending ingredients: "
                    f"{sorted(set(conflicted_names))}")
        if conflicts:
            return (f"ingredients contain forbidden properties per "
                    f"FLIngredientFacts {sorted(conflicts)} "
                    f"({sorted(set(conflicted_names))}) — claim HELD (a "
                    "contradicted claim is never machine-cleared)")
        return True
