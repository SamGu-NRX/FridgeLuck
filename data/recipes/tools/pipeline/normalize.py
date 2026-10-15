"""Name normalization for the FridgeLuck recipe pipeline.

One normalizer, used everywhere (vocabulary build, compiler, validator) so a
surface name means the same thing at every layer.
"""

from __future__ import annotations

import re
import unicodedata

# Words that describe preparation state and do not change what the food is.
# Kept as a whitelist: anything not listed stays part of the identity.
PREP_WORDS = frozenset(
    {
        "canned", "chopped", "coarsely", "cooked", "crushed", "crusty", "cubed",
        "cut", "day", "old", "diced", "dried", "drained", "defrosted", "blanched",
        "firm", "finely", "flaked", "fresh", "frozen", "grated", "halved",
        "jarred", "large", "lean", "medium", "minced", "peeled", "picked",
        "quartered", "raw", "ready", "ripe", "roasted", "rinsed", "sliced",
        "small", "stale", "thawed", "thick", "toasted", "torn", "trimmed",
        "shelled", "shredded", "squeezed", "deveined", "washed", "woody",
        "lightly", "chunked", "florets", "fillets", "fillet", "sprigs", "pods",
        "boneless", "skinless", "bone", "zest", "rind", "lardons", "lardon",
        "ends", "snapped", "reserve", "reserved", "leaves", "skin", "off",
        "chunks", "batons", "wedges", "strips", "slabs", "pulsed", "crumbs",
        "pieces", "piece", "whole", "split", "stripped", "stems", "casings",
        "removed", "pitted", "segmented", "halves", "in", "into", "of", "and",
    }
)

# Preparation phrases removed before the leading/trailing word loop.
PREP_PHRASES = (
    "cut in small florets", "cut in florets", "cut into batons", "cut into cubes",
    "cut in wedges", "peeled and cubed", "peeled and quartered", "peeled and sliced",
    "grated and squeezed", "sliced and washed", "sliced thin", "shaved thin",
    "in strips", "skin off", "in wedges", "in two thick slabs", "to crumbs",
    "woody ends snapped off", "casings removed", "leaves reserved",
    "picked over", "cut in small cubes", "halved and sliced",
    "cut into lardons", "bone in skin on", "skin on", "bone in",
)


def normalize_name(s: str) -> str:
    """Normalize a surface name to a comparison key: lowercase ascii words."""
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    s = s.lower().replace("'", "").replace("-", " ").replace("/", " or ")
    s = re.sub(r"\([^)]*\)", " ", s)  # drop parentheticals: "besan (chickpea flour)"
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    return re.sub(r"\s+", " ", s)


def strip_prep(k: str) -> str:
    """Strip trailing clauses and leading/trailing preparation words.

    'celery, chopped, leaves reserved' -> 'celery'
    'canned crushed tomatoes'          -> 'canned crushed tomatoes' is wrong ->
                                          'crushed tomatoes' ('canned' is prep)
    """
    k = k.split(",")[0].strip()
    for phrase in PREP_PHRASES:
        k = k.replace(" " + phrase, "").replace(phrase + " ", "").replace(phrase, "")
    words = [w for w in k.split() if w != "or"]
    while words and words[0] in PREP_WORDS:
        words = words[1:]
    while words and words[-1] in PREP_WORDS:
        words = words[:-1]
    return " ".join(words)


def singular(k: str) -> str:
    if k.endswith("ies") and len(k) > 4:
        return k[:-3] + "y"
    if k.endswith("oes") and len(k) > 4:
        return k[:-2]
    if k.endswith("s") and not k.endswith("ss") and len(k) > 3:
        return k[:-1]
    return k


def slugify(k: str) -> str:
    """Canonical vocabulary key form: lowercase snake_case."""
    s = normalize_name(k).replace(" ", "_")
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def extend_with_plural(alias: str) -> list[str]:
    """Return alias plus a simple plural variant (used for text matching)."""
    if alias.endswith("s"):
        return [alias]
    if alias.endswith("y"):
        return [alias, alias[:-1] + "ies"]
    return [alias, alias + "s"]
