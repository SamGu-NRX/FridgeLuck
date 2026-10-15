#!/usr/bin/env python3
"""Move corpus recipes that fail the rights gate into data/recipes/quarantine.jsonl.

SPEC 3.5: unknown rights means quarantine. A recipe whose rights record is not
affirmative evidence (rights_evidence.rights_violations) or whose
FridgeLuck-original text overlaps the bundled catalog
(rights_evidence.overlap_violation) leaves corpus.jsonl, its rights record
leaves rights_manifest.json, and both are kept in quarantine.jsonl with the
reason, so the decision can be audited or reversed once evidence exists.

quarantine.jsonl holds one object per line:

    {"id", "stage": "rights", "reason", "quarantined_on": "YYYY-MM-DD",
     "rights_record": <the record removed from the manifest, or null>,
     "recipe": <the recipe as it left the corpus>}

Default is a dry run that prints what would move; --write moves it. Running
again after --write moves nothing.

    python3 -I data/recipes/tools/quarantine.py --rights [--write]
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import corpus_io  # noqa: E402
import rights_evidence  # noqa: E402

BUNDLED = corpus_io.REPO_ROOT / "apps/ios/Resources/data.json"


def rights_failures(recipes: list[dict], records: dict, bundled: dict,
                    evidence: dict) -> dict[str, list[str]]:
    ref = rights_evidence.reference_ngrams(rights_evidence.bundled_texts(bundled))
    out: dict[str, list[str]] = {}
    for r in recipes:
        rec = records.get(r.get("source_ref"))
        problems = rights_evidence.rights_violations(r, rec, evidence)
        if isinstance(rec, dict) and rec.get("license") == "LicenseRef-FL-Original":
            hit = rights_evidence.overlap_violation(r, ref)
            if hit:
                problems.append(hit)
        if problems:
            out[r["id"]] = problems
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rights", action="store_true", required=True,
                    help="quarantine recipes failing the rights gate")
    ap.add_argument("--write", action="store_true", help="write the move (default: dry run)")
    args = ap.parse_args()

    corpus = corpus_io.read_jsonl(corpus_io.CORPUS)
    manifest = corpus_io.read_manifest()
    records = manifest["records"]
    quarantine = corpus_io.read_jsonl(corpus_io.QUARANTINE)
    bundled = json.loads(BUNDLED.read_text(encoding="utf-8"))

    failures = rights_failures([l.obj for l in corpus], records, bundled,
                               rights_evidence.load_evidence())
    today = datetime.date.today().isoformat()
    for rid, problems in sorted(failures.items()):
        print(f"quarantine {rid}:")
        for p in problems:
            print(f"  - {p}")
    print(f"{len(failures)} recipe(s) fail the rights gate; "
          f"{len(corpus) - len(failures)} stay in the corpus")
    if not args.write or not failures:
        return 0

    kept: list[corpus_io.Line] = []
    for line in corpus:
        rid = line.obj["id"]
        if rid not in failures:
            kept.append(line)
            continue
        ref = line.obj.get("source_ref")
        entry = {
            "id": rid,
            "stage": "rights",
            "reason": "; ".join(failures[rid]),
            "quarantined_on": today,
            "rights_record": records.pop(ref, None),
            "recipe": line.obj,
        }
        quarantine.append(corpus_io.Line(None, entry))
    corpus_io.write_jsonl(corpus_io.CORPUS, kept)
    corpus_io.write_manifest(manifest)
    corpus_io.write_jsonl(corpus_io.QUARANTINE, quarantine)
    print(f"wrote {corpus_io.CORPUS.name} ({len(kept)}), {corpus_io.MANIFEST.name} "
          f"({len(records)}), {corpus_io.QUARANTINE.name} ({len(quarantine)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
