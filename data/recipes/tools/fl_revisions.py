"""Derive the FridgeLuck revision records the rights evidence pins.

A corpus fix flagged ``changes_rights_pin`` changes a recipe's title or
ingredient-name list (or its full body) — the inputs the pinned authoring
record covers. After such a fix the pinned record no longer describes the
corpus recipe, and the rights gate would refuse it. The recipe stays a
FridgeLuck original: the revision is FridgeLuck's own edit of its own
LicenseRef-FL-Original text, performed in the open by the reviewed fix
packet. This module pins exactly that claim.

``derive(fix_files)`` reads the committed fix packets
(data/recipes/fixes/*.json, schema fridgeluck/corpus-fixes/v1) and returns
the ``fl_revisions`` section for data/recipes/evidence/rights.json: one
record per rights-pin fix, carrying the revised recipe's title, ingredient
-name hash, and a SHA-256 of the full revised record (canonical
sort-keys dumps). The gate accepts a recipe whose authoring record no
longer matches ONLY when a pinned revision describes the record exactly —
any other body change (a planted step edit, a renamed line, a new title)
still refuses.

Shared by apply_corpus_fixes.py (writes the section when it applies pin
fixes) and pin_rights_evidence.py (regenerates it so --check stays green).
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import corpus_io

FIXES_DIR = corpus_io.REPO_ROOT / "data/recipes/fixes"
REVISIONS_DATE = "2026-10-16"
REVISED_BY = "FridgeLuck"


def fix_files() -> list[Path]:
    """The committed corpus-fixes packets, in a stable order."""
    return sorted(FIXES_DIR.glob("*.json"))


def canonical_record_sha256(record: dict) -> str:
    """SHA-256 of the full record, canonical sort-keys dumps. Formatting and
    key order never move it; any content change does."""
    return hashlib.sha256(
        json.dumps(record, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()


def derive(fix_files_in: list[Path] | None = None) -> dict[str, dict]:
    """The fl_revisions section: {recipe_id: revision record} for every fix
    flagged changes_rights_pin across the committed fix files.

    The pin describes the corpus record as it now ships — the reviewed fix
    packet's record, plus exactly the claim-list edits strip_unproven_claims.py
    makes (it only ever removes claims the composition gate cannot prove). Any
    other delta between the fix packet and the corpus refuses here, so the pin
    can never rubber-stamp unrelated drift.
    """
    out: dict[str, dict] = {}
    corpus_by_id = {line.obj.get("id"): line.obj
                    for line in corpus_io.read_jsonl(corpus_io.CORPUS)}
    for path in (fix_files_in if fix_files_in is not None else fix_files()):
        doc = json.loads(path.read_text(encoding="utf-8"))
        if doc.get("schema") != "fridgeluck/corpus-fixes/v1":
            continue
        for fix in doc.get("fixes", []):
            if not fix.get("changes_rights_pin"):
                continue
            rid = fix["id"]
            record = fix["record"]
            if record.get("id") != rid:
                raise SystemExit(f"{path.name}: fix {rid} record id mismatch")
            if rid in out:
                raise SystemExit(f"{path.name}: two fixes pin revisions for {rid}")
            live = corpus_by_id.get(rid)
            if live is None:
                raise SystemExit(f"{path.name}: fix {rid} pins a revision but the "
                                 "recipe is not in the corpus; refusing")
            body_live = {k: v for k, v in live.items() if k != "claims"}
            body_fix = {k: v for k, v in record.items() if k != "claims"}
            if body_live != body_fix:
                raise SystemExit(
                    f"{path.name}: corpus record {rid} differs from the fix packet "
                    "beyond claim stripping; refusing to pin a revision")
            live_claims = [c.get("claim") for c in live.get("claims", [])]
            fix_claims = [c.get("claim") for c in record.get("claims", [])]
            if not set(live_claims) <= set(fix_claims):
                raise SystemExit(
                    f"{path.name}: corpus record {rid} gained claims the fix packet "
                    "does not carry; refusing to pin a revision")
            names = [i.get("name") for i in live.get("ingredients", [])
                     if isinstance(i, dict)]
            out[rid] = {
                "recipe_id": rid,
                "title": live["title"],
                "ingredients_sha256": hashlib.sha256(
                    json.dumps(names, ensure_ascii=False).encode("utf-8")
                ).hexdigest(),
                "record_sha256": canonical_record_sha256(live),
                "license": "LicenseRef-FL-Original",
                "revised_by": REVISED_BY,
                "packet": doc.get("packet", path.stem),
                "evidence": (
                    f"data/recipes/fixes/{path.name} fix {rid} (applied to the "
                    f"corpus by data/recipes/tools/apply_corpus_fixes.py)"),
                "basis": (
                    "FridgeLuck's own revision of its LicenseRef-FL-Original "
                    "recipe: the authoring record pinned at ingest predates this "
                    "reviewed edit, and the revision is FridgeLuck's own work on "
                    "its own text, not new third-party content"),
                "revised_on": REVISIONS_DATE,
                "stripped_claims": [c for c in fix_claims if c not in live_claims],
            }
    return out
