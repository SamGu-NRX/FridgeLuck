#!/usr/bin/env python3
"""Apply the corpus-fixes packets (data/recipes/fixes/*.json) to the corpus.

The fix packets (#195, #196, #197) pinned their base records by SHA-256 and
deliberately did not touch the shipped bundle. This tool is the rebuild step:
it swaps each fixed record into data/recipes/corpus.jsonl through corpus_io's
writer (unchanged lines keep their exact bytes) and pins the rights evidence
for the fixes flagged changes_rights_pin.

Fail-closed rules:
  - a fix whose before_sha256 does not match the corpus line's SHA-256
    refuses (the corpus moved under the packet — re-review, never force);
  - two files fixing the same recipe id refuse (one recipe, one decision);
  - a fix whose record id does not match its target refuses.

For fixes flagged changes_rights_pin the tool writes a "fl_revisions" section
into data/recipes/evidence/rights.json (derived by fl_revisions.py, the same
section pin_rights_evidence.py regenerates): the recipe stays a FridgeLuck
original under LicenseRef-FL-Original — the revision is FridgeLuck's own edit
of its own text — and the rights gate accepts it only against that pinned
revision.

Default is --check (write nothing); pass --write to write.

Usage:
    python3 -I data/recipes/tools/apply_corpus_fixes.py [--write]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import corpus_io  # noqa: E402
import fl_revisions  # noqa: E402

EVIDENCE = corpus_io.REPO_ROOT / "data/recipes/evidence/rights.json"


def line_sha256(raw: str) -> str:
    """The fix packets' base pin: SHA-256 of the corpus line's exact bytes
    (no trailing newline), the same digest fixes/test_amounts_b.py checks."""
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def plan(files: list[Path], lines: list[corpus_io.Line]) -> dict[str, tuple[dict, dict]]:
    """Validate every fix against the corpus and return {recipe_id: (record,
    fix)}; any refusal is a hard exit."""
    by_id = {line.obj.get("id"): line for line in lines}
    planned: dict[str, tuple[dict, dict]] = {}
    for path in files:
        doc = json.loads(path.read_text(encoding="utf-8"))
        if doc.get("schema") != "fridgeluck/corpus-fixes/v1":
            raise SystemExit(f"{path.name}: schema {doc.get('schema')!r} is not "
                             "fridgeluck/corpus-fixes/v1")
        for fix in doc.get("fixes", []):
            fid = fix.get("id")
            record = fix.get("record")
            if fid not in by_id:
                raise SystemExit(f"{path.name}: fix {fid!r} is not in the corpus")
            if fid in planned:
                raise SystemExit(f"{path.name}: two files fix {fid} — one recipe, "
                                 "one decision; refusing")
            if not isinstance(record, dict) or record.get("id") != fid:
                raise SystemExit(f"{path.name}: fix {fid!r} record id mismatch")
            if line_sha256(by_id[fid].raw) != fix.get("before_sha256"):
                raise SystemExit(
                    f"{path.name}: fix {fid} before_sha256 does not match the "
                    "corpus line (the corpus moved under the packet); refusing")
            planned[fid] = (record, fix)
    return planned


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    files = fl_revisions.fix_files()
    lines = corpus_io.read_jsonl(corpus_io.CORPUS)
    planned = plan(files, lines)

    pin_fixes = {rid: fix for rid, (_, fix) in planned.items()
                 if fix.get("changes_rights_pin")}

    if not args.write:
        print(f"{len(files)} fix files: {len(planned)} recipes to update "
              f"({len(pin_fixes)} rights-pin revisions to pin)")
        print("dry run — pass --write to write")
        return 0

    for rid, (record, _) in planned.items():
        for line in lines:
            if line.obj.get("id") == rid:
                line.obj = record
                break
    corpus_io.write_jsonl(corpus_io.CORPUS, lines)

    # Derive the revision pins from the freshly written corpus (they describe
    # the records as they now ship); strip_unproven_claims.py may later remove
    # unproven claims, after which pin_rights_evidence.py refreshes the pins.
    revisions = fl_revisions.derive(files)
    if set(revisions) != set(pin_fixes):
        raise SystemExit("revision derivation disagrees with the pin flags; refusing")
    evidence = json.loads(EVIDENCE.read_text(encoding="utf-8"))
    evidence["fl_revisions"] = revisions
    EVIDENCE.write_text(json.dumps(evidence, ensure_ascii=False, indent=1,
                                   sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {corpus_io.CORPUS.name} ({len(planned)} records) and "
          f"{EVIDENCE.name} (fl_revisions: {len(revisions)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
