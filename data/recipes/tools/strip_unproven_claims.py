#!/usr/bin/env python3
"""Remove allergen and diet claims the composition gate cannot prove.

Runs composition.claim_problems over every corpus recipe with suite C's
allergen table and deletes each refused claim. It never adds or rewrites a
claim, so a recipe can only lose claims. Prints the count removed per claim
type and per reason. Re-running after --write removes nothing.

    python3 -I data/recipes/tools/strip_unproven_claims.py \
        --suite-dir <extracted evaluation/suites/recipes> [--write]
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import composition  # noqa: E402
import corpus_io  # noqa: E402


def reason_kind(reason: str) -> str:
    for prefix, kind in (("composition unknown", "unknown composition"),
                         ("line offers alternatives", "alternatives"),
                         ("a step names", "conflicting food named in a step"),
                         ("recorded conflicts", "evidence mismatch"),
                         ("contains forbidden", "forbidden class present")):
        if reason.startswith(prefix):
            return kind
    return "product-dependent composition"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--suite-dir", required=True, type=Path,
                    help="extracted evaluation/suites/recipes (for allergens.json)")
    ap.add_argument("--write", action="store_true", help="write corpus.jsonl (default: dry run)")
    args = ap.parse_args()
    table = json.loads((args.suite_dir / "allergens.json").read_text(encoding="utf-8"))

    lines = corpus_io.read_jsonl(corpus_io.CORPUS)
    before = sum(len(l.obj.get("claims", [])) for l in lines)
    by_claim: collections.Counter[str] = collections.Counter()
    by_reason: collections.Counter[str] = collections.Counter()
    for line in lines:
        r = line.obj
        problems = composition.claim_problems(r, table)
        if not problems:
            continue
        for cname, reasons in problems.items():
            by_claim[cname] += 1
            for kind in {reason_kind(x) for x in reasons}:
                by_reason[kind] += 1
        r["claims"] = [c for c in r.get("claims", []) if c.get("claim") not in problems]
    after = sum(len(l.obj.get("claims", [])) for l in lines)
    print(f"claims: {before} before, {after} kept, {before - after} removed")
    for cname, n in sorted(by_claim.items()):
        print(f"  removed {cname}: {n}")
    print("removed claims by reason (a claim can have several):")
    for kind, n in by_reason.most_common():
        print(f"  {kind}: {n}")
    if args.write and before != after:
        corpus_io.write_jsonl(corpus_io.CORPUS, lines)
        print(f"wrote {corpus_io.CORPUS.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
