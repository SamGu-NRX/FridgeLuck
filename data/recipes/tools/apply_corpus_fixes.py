#!/usr/bin/env python3
"""Apply the corpus-fixes packets (data/recipes/fixes/*.json) to the corpus.

The fix packets (#195, #196, #197, #214, #220) pinned their base records by
SHA-256 and deliberately did not touch the shipped bundle. This tool is the
rebuild step: it swaps each fixed record into data/recipes/corpus.jsonl
through corpus_io's writer (unchanged lines keep their exact bytes) and pins
the rights evidence for the fixes flagged changes_rights_pin.

Fail-closed rules:
  - a fix whose before_sha256 does not match the corpus line's SHA-256
    refuses (the corpus moved under the packet — re-review, never force);
  - two files fixing the same recipe id refuse (one recipe, one decision),
    unless the later fix is a follow-up review of the earlier one: its
    before_sha256 pins the earlier fix's record (review-fixed.json reviews
    the records amounts-a/amounts-b wrote). Each recipe's fixes must form one
    such chain; two fixes from the same base, or a fix that pins neither the
    corpus nor another fix, still refuse;
  - a fix whose record id does not match its target refuses.

Packets already applied cannot be applied again (their before_sha256 now
points at replaced lines), so --packet names the packets to apply this run;
the chain and id rules above still check every committed packet.

For fixes flagged changes_rights_pin the tool writes a "fl_revisions" section
into data/recipes/evidence/rights.json (derived by fl_revisions.py, the same
section pin_rights_evidence.py regenerates): the recipe stays a FridgeLuck
original under LicenseRef-FL-Original — the revision is FridgeLuck's own edit
of its own text — and the rights gate accepts it only against that pinned
revision.

Default is --check (write nothing); pass --write to write.

Usage:
    python3 -I data/recipes/tools/apply_corpus_fixes.py [--packet NAME ...] [--write]
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


def record_sha256(record: dict) -> str:
    """The digest a follow-up packet pins when its base is an earlier fix's
    record: the line the packets serialize it as (json.dumps, UTF-8 kept)."""
    return line_sha256(json.dumps(record, ensure_ascii=False))


def load_fixes(files: list[Path]) -> list[tuple[str, dict]]:
    """Every fix of every packet as (packet file name, fix), in file order."""
    out: list[tuple[str, dict]] = []
    for path in files:
        doc = json.loads(path.read_text(encoding="utf-8"))
        if doc.get("schema") != "fridgeluck/corpus-fixes/v1":
            raise SystemExit(f"{path.name}: schema {doc.get('schema')!r} is not "
                             "fridgeluck/corpus-fixes/v1")
        for fix in doc.get("fixes", []):
            fid = fix.get("id")
            record = fix.get("record")
            if not isinstance(record, dict) or record.get("id") != fid:
                raise SystemExit(f"{path.name}: fix {fid!r} record id mismatch")
            out.append((path.name, fix))
    return out


def chains(fixes: list[tuple[str, dict]]) -> dict[str, list[tuple[str, dict]]]:
    """{recipe_id: [(file, fix), ...]} ordered from the fix that pins the
    original corpus line to the latest follow-up. Refuses any recipe whose
    fixes do not form one chain."""
    by_id: dict[str, list[tuple[str, dict]]] = {}
    for name, fix in fixes:
        by_id.setdefault(fix["id"], []).append((name, fix))
    out: dict[str, list[tuple[str, dict]]] = {}
    for fid, entries in by_id.items():
        if len(entries) == 1:
            out[fid] = entries
            continue
        names = [n for n, _ in entries]
        if len(set(names)) != len(names):
            raise SystemExit(f"{names[0]}: fixes {fid} twice; refusing")
        produced = {record_sha256(f["record"]) for _, f in entries}
        roots = [e for e in entries if e[1].get("before_sha256") not in produced]
        if len(roots) != 1:
            raise SystemExit(
                f"two files fix {fid} ({', '.join(names)}) and neither is a "
                "follow-up of the other — one recipe, one decision; refusing")
        chain = [roots[0]]
        while len(chain) < len(entries):
            tip = record_sha256(chain[-1][1]["record"])
            nxt = [e for e in entries if e[1].get("before_sha256") == tip]
            if len(nxt) != 1:
                raise SystemExit(
                    f"two files fix {fid} ({', '.join(names)}) from the same base "
                    "— one recipe, one decision; refusing")
            chain.append(nxt[0])
        out[fid] = chain
    return out


def plan(files: list[Path], lines: list[corpus_io.Line],
         apply: set[str] | None = None) -> dict[str, tuple[dict, dict]]:
    """Validate every committed fix and return {recipe_id: (record, fix)} for
    the fixes in the `apply` packets (file names; None = every file). Within
    one recipe's chain the applied fixes must be consecutive; the first must
    pin the current corpus line, and the record shipped is the last one's.
    Any refusal is a hard exit."""
    by_id = {line.obj.get("id"): line for line in lines}
    names = {path.name for path in files}
    if apply is not None and not apply <= names:
        raise SystemExit(f"unknown packet(s): {', '.join(sorted(apply - names))}")
    planned: dict[str, tuple[dict, dict]] = {}
    for fid, chain in chains(load_fixes(files)).items():
        picked = [i for i, (name, _) in enumerate(chain)
                  if apply is None or name in apply]
        if not picked:
            continue
        if picked != list(range(picked[0], picked[-1] + 1)):
            raise SystemExit(f"{fid}: the packets to apply skip a link of its "
                             "fix chain; refusing")
        name, first = chain[picked[0]]
        if fid not in by_id:
            raise SystemExit(f"{name}: fix {fid!r} is not in the corpus")
        if line_sha256(by_id[fid].raw) != first.get("before_sha256"):
            raise SystemExit(
                f"{name}: fix {fid} before_sha256 does not match the "
                "corpus line (the corpus moved under the packet); refusing")
        last = chain[picked[-1]][1]
        planned[fid] = (last["record"], last)
    return planned


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--packet", action="append", metavar="NAME",
                    help="fix file name to apply (repeatable; default: all)")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    files = fl_revisions.fix_files()
    lines = corpus_io.read_jsonl(corpus_io.CORPUS)
    planned = plan(files, lines, set(args.packet) if args.packet else None)

    # The rights pins cover every committed packet, applied this run or earlier.
    pin_fixes = {fix["id"] for _, fix in load_fixes(files)
                 if fix.get("changes_rights_pin")}
    new_pins = sorted(rid for rid, (_, fix) in planned.items()
                      if fix.get("changes_rights_pin"))

    if not args.write:
        print(f"{len(files)} fix files: {len(planned)} recipes to update "
              f"({len(new_pins)} rights-pin revisions to pin)")
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
    if set(revisions) != pin_fixes:
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
