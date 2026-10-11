"""Household-measure parsing helpers for USDA FNDDS portion data.

Parses FNDDS ``portionDescription`` strings such as "1 cup", "2 tbsp",
"1/2 cup", "1 medium (2-1/2\" dia)" into a canonical (magnitude, unit) pair
when the description names a recognizable household measure.

Descriptions like "Quantity not specified" or "Guideline amount per ..." do
not name a household measure and are excluded.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass

# Canonical unit vocabulary. Keys are the canonical unit names used in derived
# tables and in the Swift MassConversionKit resource; values are regex fragments
# matched case-insensitively against the unit token right after the magnitude.
# Order matters: "fl oz" / "fluid ounce" must be tried before "oz". A trailing
# qualifier such as "(no ice)", ", cooked, diced", or " yields" is allowed after
# every unit token, so the fragments below only need the core token.
_QUALIFIER = r"(?:\s*\([^)]*\))*(?:\s*,[^,]*(?:,[^,]*)*)?(?:\s+yields?\b.*)?"
UNIT_PATTERNS: list[tuple[str, str]] = [
    ("cup", r"cups?"),
    ("tbsp", r"(?:tbsps?|tbl|tablespoons?)"),
    ("tsp", r"(?:tsps?|teaspoons?)"),
    ("floz", r"(?:fl\s*oz|fluid\s*ounces?|fluid\s*ounce)"),
    ("oz", r"(?:ozs?|ounces?)(?!\s*(?:fl|fluid))"),
    ("lb", r"(?:lbs?|pounds?)"),
    ("quart", r"quarts?"),
    ("pint", r"pints?"),
    ("gallon", r"gallons?"),
    ("liter", r"(?:liters?|litres?)"),
    ("stick", r"sticks?"),
    ("slice", r"slices?"),
    ("piece", r"pieces?"),
    ("strip", r"strips?"),
    ("pat", r"pats?"),
    ("clove", r"cloves?"),
    ("ear", r"ears?"),
    ("small", r"small"),
    ("medium", r"medium"),
    ("large", r"large"),
    ("regular", r"regular"),
    ("egg", r"eggs?"),
    ("can", r"cans?"),
    ("package", r"(?:packages?|packs?|pkg)"),
    ("envelope", r"(?:envelopes?|env)"),
]

# Leading magnitude: integer, decimal, simple fraction (1/2), or mixed (1-1/2).
_MAGNITUDE_RE = re.compile(
    r"^(?P<mixed>\d+)(?:-(?P<num>\d+)/(?P<den>\d+))"
    r"|^(?:(?P<num2>\d+)/(?P<den2>\d+))"
    r"|^(?P<dec>\d+(?:\.\d+)?)"
)

_HOUSEHOLD_RE = re.compile(
    r"^(?P<magnitude>\d+(?:\.\d+)?(?:/\d+)?(?:-\d+/\d+)?)\s+(?P<rest>.+)$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class ParsedPortion:
    """A portion description resolved to a canonical household measure."""

    magnitude: float
    unit: str
    raw_description: str


def parse_magnitude(text: str) -> float | None:
    """Parse a leading quantity such as "2", "0.5", "1/2", or "1-1/2"."""
    text = text.strip()
    m = _MAGNITUDE_RE.match(text)
    if not m:
        return None
    if m.group("mixed") is not None:
        whole = float(m.group("mixed"))
        frac = float(m.group("num")) / float(m.group("den"))
        return whole + frac
    if m.group("num2") is not None:
        return float(m.group("num2")) / float(m.group("den2"))
    return float(m.group("dec"))


def parse_portion_description(description: str) -> ParsedPortion | None:
    """Return a :class:`ParsedPortion` when the description names a household
    measure we model, else ``None``.

    Examples:
      >>> parse_portion_description("1 cup")
      ParsedPortion(magnitude=1.0, unit='cup', ...)
      >>> parse_portion_description("Quantity not specified") is None
      True
    """
    if not description:
        return None
    text = description.strip()
    m = _HOUSEHOLD_RE.match(text)
    if not m:
        return None
    magnitude = parse_magnitude(m.group("magnitude"))
    if magnitude is None or magnitude <= 0:
        return None
    rest = m.group("rest").strip().lower()
    for canonical, pattern in UNIT_PATTERNS:
        unit_match = re.fullmatch(pattern + _QUALIFIER, rest)
        if unit_match:
            return ParsedPortion(
                magnitude=magnitude, unit=canonical, raw_description=text
            )
    return None


# Preparation-state keywords, in priority order (first hit wins). Priority
# resolves combined phrases: "prepared from frozen, heated" -> frozen, because
# frozen outranks the cooking words.
_STATE_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("frozen", ("frozen",)),
    ("thawed", ("thawed",)),
    ("dried", ("dry", "dried", "not reconstituted")),
    (
        "cooked",
        (
            "cooked",
            "baked",
            "boiled",
            "braised",
            "fried",
            "grilled",
            "heated",
            "prepared",
            "reconstituted",
            "roasted",
            "steamed",
            "stewed",
        ),
    ),
    ("raw", ("raw",)),
]

# Packing/container keywords (orthogonal to preparation state).
_PACKING_KEYWORDS: dict[str, tuple[str, ...]] = {
    "canned": ("canned",),
    "jarred": ("jar",),
    "packaged": ("packaged",),
}


def _word_in(text: str, word: str) -> bool:
    return re.search(rf"\b{re.escape(word)}\b", text) is not None


def classify_preparation_state(text: str) -> str | None:
    """Canonical preparation state (``cooked``, ``frozen``, ...) or ``None``.

    Scans FNDDS portion-description qualifier text (e.g. "1 cup, cooked,
    diced") and portion modifiers for state keywords; first keyword family in
    :data:`_STATE_KEYWORDS` priority order wins. State words are matched on
    word boundaries, so unit tokens like "cup" or "can" never match.
    """
    lowered = (text or "").lower()
    for state, words in _STATE_KEYWORDS:
        if any(_word_in(lowered, word) for word in words):
            return state
    return None


def classify_packing(text: str) -> str | None:
    """Canonical packing (``canned``, ``jarred``, ``packaged``) or ``None``."""
    lowered = (text or "").lower()
    for packing, words in _PACKING_KEYWORDS.items():
        if any(_word_in(lowered, word) for word in words):
            return packing
    return None


# State words stripped when normalizing a survey-food description to its
# stem: the union of every preparation-state vocabulary above, so two
# descriptions that differ only by preparation wording share a stem
# ("Chard, raw" and "Chard, cooked" both stem to ("chard",)). Packing
# words are NOT state words and survive stemming ("... , canned" stays).
STATE_STEM_WORDS: frozenset[str] = frozenset(
    word for _state, words in _STATE_KEYWORDS for word in words
)

# Container/packing vocabulary scanned over the full FNDDS corpus in the
# packing-evidence arm (word-boundary matches; report-only, never a
# label source — labeling stays with :func:`classify_packing`).
PACKING_SCAN_TERMS: tuple[str, ...] = (
    "canned", "jarred", "packaged", "can", "cans", "jar", "jars", "bag",
    "bags", "bagged", "bottle", "bottles", "bottled", "box", "boxes",
    "boxed", "tin", "tins", "pouch", "pouches", "package", "packages",
    "pack", "packs", "pkg", "carton", "cartons", "tub", "tubs",
)


def normalize_description_stem(text: str) -> tuple[str, ...]:
    """Lowercase alphanumeric tokens of a food description with every
    preparation-state word removed.

    >>> normalize_description_stem("Chard, raw")
    ('chard',)
    >>> normalize_description_stem("Apple, baked")
    ('apple',)
    """
    return tuple(
        token
        for token in re.split(r"[^a-z0-9]+", (text or "").lower())
        if token and token not in STATE_STEM_WORDS
    )


def derive_yield_pairs(
    foods: list[dict],
    units_by_food: dict[int, dict[str, float]],
    nutrients_by_food: dict[int, dict[str, float]],
) -> tuple[list[dict], list[dict]]:
    """Derive source-bound raw-to-cooked yield pairs from FNDDS survey foods.

    A candidate joins two survey foods in the SAME WWEIA category whose
    normalized description stems (:func:`normalize_description_stem`) are
    equal, with one classified ``raw`` and the other ``cooked`` from the
    description itself. A candidate becomes a pair when the two foods share
    at least one canonical household unit whose per-unit grams differ and
    all four nutrient anchors (kcal, protein, fat, carbohydrate per 100 g)
    exist on both sides; every other candidate is returned as an explicit
    missing-input record — nothing is filled.

    Returns ``(pairs, missing_inputs)``. Pair records carry the raw and
    cooked fdcId/description, the shared unit, per-unit grams of each side,
    and ``ratio`` = cooked grams per unit ÷ raw grams per unit.
    """

    by_category: dict[tuple[str, int], dict] = {}
    for food in foods:
        fid = food.get("fdcId")
        by_category[
            (
                (food.get("wweiaFoodCategory") or {}).get(
                    "wweiaFoodCategoryDescription", ""
                ),
                fid,
            )
        ] = food

    groups: dict[str, list[dict]] = {}
    for (category, _fid), food in by_category.items():
        groups.setdefault(category, []).append(food)

    pairs: list[dict] = []
    missing: list[dict] = []
    seen_pairs: set[tuple[int, int, str]] = set()
    for category in sorted(groups):
        for a in sorted(groups[category], key=lambda f: f["fdcId"]):
            description_a = a.get("description") or ""
            state_a = classify_preparation_state(description_a)
            if state_a not in ("raw", "cooked"):
                continue
            stem_a = normalize_description_stem(description_a)
            for b in sorted(groups[category], key=lambda f: f["fdcId"]):
                if b["fdcId"] <= a["fdcId"]:
                    continue
                description_b = b.get("description") or ""
                state_b = classify_preparation_state(description_b)
                if state_b not in ("raw", "cooked") or state_b == state_a:
                    continue
                if normalize_description_stem(description_b) != stem_a:
                    continue
                raw, cooked = (
                    (a, b) if state_a == "raw" else (b, a)
                )
                shared = sorted(
                    set(units_by_food.get(raw["fdcId"], {}))
                    & set(units_by_food.get(cooked["fdcId"], {}))
                )
                differing = [
                    unit
                    for unit in shared
                    if units_by_food[raw["fdcId"]][unit]
                    != units_by_food[cooked["fdcId"]][unit]
                ]
                base = {
                    "category": category,
                    "rawFdcId": raw["fdcId"],
                    "cookedFdcId": cooked["fdcId"],
                    "rawFood": raw.get("description") or "",
                    "cookedFood": cooked.get("description") or "",
                }
                if not differing:
                    missing.append({**base, "reason": "no shared unit with differing grams"})
                    continue
                nutrient_gap = any(
                    nutrients_by_food.get(food["fdcId"], {}).get(name) is None
                    for food in (raw, cooked)
                    for name in ("kcal", "proteinG", "fatG", "carbG")
                )
                if nutrient_gap:
                    for unit in differing:
                        missing.append({**base, "unit": unit, "reason": "missing nutrients"})
                    continue
                for unit in differing:
                    key = (raw["fdcId"], cooked["fdcId"], unit)
                    if key in seen_pairs:
                        continue
                    seen_pairs.add(key)
                    raw_grams = units_by_food[raw["fdcId"]][unit]
                    cooked_grams = units_by_food[cooked["fdcId"]][unit]
                    pairs.append(
                        {
                            **base,
                            "unit": unit,
                            "rawGramsPerUnit": raw_grams,
                            "cookedGramsPerUnit": cooked_grams,
                            "ratio": cooked_grams / raw_grams,
                        }
                    )
    pairs.sort(key=lambda p: (p["category"], p["rawFdcId"], p["cookedFdcId"], p["unit"]))
    missing.sort(key=lambda m: (m["category"], m["rawFdcId"], m["cookedFdcId"], m.get("unit", "")))
    return pairs, missing


def scan_packing_terms(foods: list[dict]) -> dict:
    """Word-boundary scan of every survey portion's description+modifier
    text for the :data:`PACKING_SCAN_TERMS` vocabulary.

    Returns raw per-term counts over the full corpus, the same counts
    restricted to rows that parse into canonical household units, and the
    qualifier-level hits where :func:`classify_packing` would actually
    label a parsed row. Container words appearing as quantity units
    ("1 can", "1 package") count as term hits but are not packing
    qualifiers.
    """
    all_counts: Counter[str] = Counter()
    parsed_counts: Counter[str] = Counter()
    qualifier_hits: list[dict] = []
    portions_scanned = 0
    parsed_scanned = 0
    for food in foods:
        for portion in food.get("foodPortions") or []:
            text = " ".join(
                (portion.get("portionDescription") or "", portion.get("modifier") or "")
            ).strip()
            if not text:
                continue
            portions_scanned += 1
            hits = [
                term
                for term in PACKING_SCAN_TERMS
                if _word_in(text.lower(), term)
            ]
            if hits:
                all_counts.update(hits)
            parsed = parse_portion_description(
                portion.get("portionDescription") or ""
            )
            if parsed is None:
                continue
            parsed_scanned += 1
            if hits:
                parsed_counts.update(hits)
            packing = classify_packing(text)
            if packing is not None:
                qualifier_hits.append(
                    {
                        "fdcId": food.get("fdcId"),
                        "food": food.get("description") or "",
                        "category": (food.get("wweiaFoodCategory") or {}).get(
                            "wweiaFoodCategoryDescription", ""
                        ),
                        "portionDescription": portion.get("portionDescription") or "",
                        "modifier": portion.get("modifier") or "",
                        "unit": parsed.unit,
                        "magnitude": parsed.magnitude,
                        "classification": packing,
                    }
                )
    return {
        "portionsScanned": portions_scanned,
        "termCounts": dict(sorted(all_counts.items())),
        "parsedHouseholdRows": parsed_scanned,
        "parsedTermCounts": dict(sorted(parsed_counts.items())),
        "qualifierPackingHits": qualifier_hits,
    }
