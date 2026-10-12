"""Rights gate: a corpus recipe ships only on affirmative rights evidence.

SPEC 3.5: "Unknown rights means quarantine." suite C's rights.py checks that a
record is complete (every field present, permissions true). It cannot tell
whether the evidence behind the record proves anything. The 25 bundled seeds
passed it with license_evidence that only listed absences: no Source line,
present since the initial commit, title not in the BBC scrape cache. None of
those shows who wrote the text or that anyone gave permission.

This gate accepts a record only when the evidence it cites is pinned in
data/recipes/evidence/rights.json (written by pin_rights_evidence.py) and
agrees with it. An original must cite its authoring record by id and commit;
the pinned record must exist at that commit, carry LicenseRef-FL-Original
and the app's permissions, and describe this recipe (same title, same
ingredient names). An external source must be pinned with the verdict
"verified" for its terms; a source whose terms were checked and found not to
grant the use is refused with the pinned reason. A citation's spelling alone
never clears a recipe, and a source_type with no form here is refused.

It also tests the claim that FridgeLuck-original text is original:
`overlap_violation` refuses an original whose title and steps share a run of
`MAX_SHARED_WORDS` or more consecutive words with any bundled-catalog recipe
(the BBC-sourced text the rewrites replace). Measured on the 401 originals on
2026-10-11, the longest shared run is 9 words, all stock phrases ("pinch of
salt in a small bowl", "pour in the stock and bring to").
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, Iterable

_ORIGINALS_RECORD = re.compile(
    r"^data/recipes/originals/rights_manifest\.json record (?P<id>fl-original-\d{4}) "
    r"\(branch overhaul/original-recipes at (?P<sha>[0-9a-f]{7,40})\)")
_URL = re.compile(r"https://[^\s;,)]+")

# Evidence that describes what is missing rather than who holds the rights.
_ABSENCE = re.compile(
    r"no Source line|not in the BBC scrape cache|title not in|in repo since|"
    r"initial commit|no source recorded|absent from", re.IGNORECASE)

MAX_SHARED_WORDS = 12
APP_PERMISSIONS = ("text", "modification", "caching", "offline_use")
EVIDENCE_PATH = Path(__file__).resolve().parents[1] / "evidence" / "rights.json"


def load_evidence(path: Path = EVIDENCE_PATH) -> dict[str, Any]:
    """The pinned evidence; a missing file is an error, never an empty pass."""
    if not path.is_file():
        raise SystemExit(f"{path} is missing; run tools/pin_rights_evidence.py")
    return json.loads(path.read_text(encoding="utf-8"))


def ingredients_sha256(recipe: dict[str, Any]) -> str:
    names = [str(i.get("name")) for i in recipe.get("ingredients", []) if isinstance(i, dict)]
    return hashlib.sha256(json.dumps(names, ensure_ascii=False).encode("utf-8")).hexdigest()


def _original_form(recipe: dict[str, Any], rec: dict[str, Any],
                   evidence: dict[str, Any]) -> str | None:
    m = _ORIGINALS_RECORD.match(str(rec.get("license_evidence", "")))
    if not m:
        return ("license_evidence does not cite the authoring task's record "
                "(data/recipes/originals/rights_manifest.json record <id> "
                "(branch overhaul/original-recipes at <sha>))")
    rid = recipe.get("id")
    if m.group("id") != rid:
        return f"license_evidence cites the authoring record for {m.group('id')}, not {rid}"
    pinned = evidence.get("originals", {})
    if not str(pinned.get("commit", "")).startswith(m.group("sha")):
        return (f"cited commit {m.group('sha')} is not the pinned originals commit "
                f"{pinned.get('commit')!r}; the record cannot be verified")
    prec = pinned.get("records", {}).get(rid)
    if prec is None:
        return f"no authoring record for {rid} at {m.group('sha')}"
    if prec.get("license") != "LicenseRef-FL-Original" or rec.get("license") != prec["license"]:
        return "the authoring record does not license this as FridgeLuck-original text"
    if prec.get("source_type") != rec.get("source_type"):
        return (f"source_type {rec.get('source_type')!r} differs from the authoring "
                f"record's {prec.get('source_type')!r}")
    denied = [p for p in APP_PERMISSIONS if prec.get("permissions", {}).get(p) is not True]
    if denied:
        return f"the authoring record does not grant {denied}"
    if prec.get("title") != recipe.get("title") or \
            prec.get("ingredients_sha256") != ingredients_sha256(recipe):
        return f"the authoring record for {rid} describes a different recipe"
    return None


def _external_form(recipe: dict[str, Any], rec: dict[str, Any],
                   evidence: dict[str, Any]) -> str | None:
    source = evidence.get("sources", {}).get(str(rec.get("source_id")))
    if source is None:
        return (f"source {rec.get('source_id')!r} has no pinned terms evidence; "
                "its licence cannot be verified")
    if source.get("verdict") != "verified":
        return f"source terms checked and not verified: {source.get('reason')}"
    pages = source.get("pages", {})
    cited = _URL.findall(str(rec.get("license_evidence", "")))
    unpinned = [u for u in cited if u not in pages]
    if not cited or unpinned:
        return f"cited pages {unpinned or cited} are not pinned evidence"
    return None


AFFIRMATIVE_FORMS = {
    "original": _original_form,
    "original-rewrite": _original_form,
    "government": _external_form,
}


def rights_violations(recipe: dict[str, Any], rec: Any, evidence: dict[str, Any]) -> list[str]:
    """Why this recipe's rights record is not verified affirmative evidence
    (empty = ok). `evidence` is data/recipes/evidence/rights.json."""
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
        problem = form(recipe, rec, evidence)
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
