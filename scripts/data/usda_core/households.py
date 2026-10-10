"""Household-measure parsing helpers for USDA FNDDS portion data.

Parses FNDDS ``portionDescription`` strings such as "1 cup", "2 tbsp",
"1/2 cup", "1 medium (2-1/2\" dia)" into a canonical (magnitude, unit) pair
when the description names a recognizable household measure.

Descriptions like "Quantity not specified" or "Guideline amount per ..." do
not name a household measure and are excluded.
"""

from __future__ import annotations

import re
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
