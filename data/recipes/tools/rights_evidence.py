"""Rights gate: a corpus recipe ships only on affirmative rights evidence.

SPEC 3.5: "Unknown rights means quarantine." suite C's rights.py checks that a
record is complete (every field present, permissions true). It cannot tell
whether the evidence behind the record proves anything. The 25 bundled seeds
passed it with license_evidence that only listed absences: no Source line,
present since the initial commit, title not in the BBC scrape cache. None of
those shows who wrote the text or that anyone gave permission.

This gate accepts a record only when its evidence takes one of the forms in
`AFFIRMATIVE_FORMS`, keyed by source_type, and refuses any source_type it has
no form for. Adding a source means adding its form here, on purpose.

It also tests the claim that FridgeLuck-original text is original:
`overlap_violation` refuses an original whose title and steps share a run of
`MAX_SHARED_WORDS` or more consecutive words with any bundled-catalog recipe
(the BBC-sourced text the rewrites replace). Measured on the 401 originals on
2026-10-11, the longest shared run is 9 words, all stock phrases ("pinch of
salt in a small bowl", "pour in the stock and bring to").
"""

from __future__ import annotations

import re
from typing import Any, Iterable

# License strings that grant the app's required permissions by their terms.
OPEN_LICENCES = {"OGL-3.0"}

_ORIGINALS_RECORD = re.compile(
    r"^data/recipes/originals/rights_manifest\.json record (?P<id>fl-original-\d{4}) "
    r"\(branch overhaul/original-recipes at [0-9a-f]{7,40}\)")
_URL = re.compile(r"https://\S+")

# Evidence that describes what is missing rather than who holds the rights.
_ABSENCE = re.compile(
    r"no Source line|not in the BBC scrape cache|title not in|in repo since|"
    r"initial commit|no source recorded|absent from", re.IGNORECASE)

MAX_SHARED_WORDS = 12


def _original_form(recipe: dict[str, Any], rec: dict[str, Any]) -> str | None:
    m = _ORIGINALS_RECORD.match(str(rec.get("license_evidence", "")))
    if not m:
        return ("license_evidence does not cite the authoring task's record "
                "(data/recipes/originals/rights_manifest.json record <id> "
                "(branch overhaul/original-recipes at <sha>))")
    if m.group("id") != recipe.get("id"):
        return (f"license_evidence cites the authoring record for {m.group('id')}, "
                f"not {recipe.get('id')}")
    if rec.get("license") != "LicenseRef-FL-Original":
        return "an original must carry license LicenseRef-FL-Original"
    return None


def _open_licence_form(recipe: dict[str, Any], rec: dict[str, Any]) -> str | None:
    if rec.get("license") not in OPEN_LICENCES:
        return (f"license {rec.get('license')!r} is not one of the open licences "
                f"{sorted(OPEN_LICENCES)}")
    urls = _URL.findall(str(rec.get("license_evidence", "")))
    if len(urls) < 2:
        return ("license_evidence must link both the licence terms and the "
                "recipe's own page")
    return None


AFFIRMATIVE_FORMS = {
    "original": _original_form,
    "original-rewrite": _original_form,
    "government": _open_licence_form,
}


def rights_violations(recipe: dict[str, Any], rec: Any) -> list[str]:
    """Why this recipe's rights record is not affirmative evidence (empty = ok)."""
    rid = recipe.get("id", "?")
    if not isinstance(rec, dict):
        return [f"{rid}: no rights record"]
    out: list[str] = []
    stype = str(rec.get("source_type", ""))
    form = AFFIRMATIVE_FORMS.get(stype)
    if form is None:
        out.append(f"{rid}: no affirmative-evidence form for source_type {stype!r}; "
                   "add one to rights_evidence.AFFIRMATIVE_FORMS before shipping it")
    else:
        problem = form(recipe, rec)
        if problem:
            out.append(f"{rid}: {problem}")
    evidence = f"{rec.get('origin', '')} {rec.get('license_evidence', '')}"
    hit = _ABSENCE.search(evidence)
    if hit:
        out.append(f"{rid}: rights rest on missing attribution ({hit.group(0)!r}), "
                   "which proves neither authorship nor permission")
    return out


# ---------------------------------------------------------------------------
# originality of FridgeLuck-original text
# ---------------------------------------------------------------------------


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", str(text).lower())


def reference_ngrams(texts: Iterable[str], n: int = MAX_SHARED_WORDS) -> set[tuple[str, ...]]:
    grams: set[tuple[str, ...]] = set()
    for text in texts:
        w = words(text)
        grams.update(tuple(w[i:i + n]) for i in range(len(w) - n + 1))
    return grams


def recipe_text(recipe: dict[str, Any]) -> str:
    parts = [str(recipe.get("title", ""))]
    parts += [str(s.get("text", "")) for s in recipe.get("steps", []) if isinstance(s, dict)]
    return " ".join(parts)


def overlap_violation(recipe: dict[str, Any], ref: set[tuple[str, ...]],
                      n: int = MAX_SHARED_WORDS) -> str | None:
    w = words(recipe_text(recipe))
    for i in range(len(w) - n + 1):
        gram = tuple(w[i:i + n])
        if gram in ref:
            return (f"{recipe.get('id', '?')}: text recorded as FridgeLuck-original shares "
                    f"{n} consecutive words with the bundled catalog: {' '.join(gram)!r}")
    return None


def bundled_texts(bundled: dict[str, Any]) -> list[str]:
    """Title + instructions of every recipe row in apps/ios/Resources/data.json."""
    out = []
    for row in bundled.get("recipes", []):
        if isinstance(row, list) and len(row) >= 7:
            out.append(f"{row[1]} {row[6]}")
    return out
