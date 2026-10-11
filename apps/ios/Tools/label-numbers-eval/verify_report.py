#!/usr/bin/env python3
"""Byte-verify the committed label-numbers report.

Recomputes reports/report.json from the committed corpus and prediction
files and compares the bytes. Any edit to the corpus, either prediction
file, or the report itself changes the recomputation and fails the check.
Exits 0 on a byte match, 1 on a mismatch, 2 on missing inputs.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from score_report import build_report, canonical_json


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--corpus", default="corpus/labels.jsonl")
    ap.add_argument("--production", default="reports/replay_predictions.jsonl")
    ap.add_argument("--strict", default="reports/strict_predictions.jsonl")
    ap.add_argument("--report", default="reports/report.json")
    args = ap.parse_args()

    paths = {
        "corpus": Path(args.corpus),
        "production": Path(args.production),
        "strict": Path(args.strict),
        "report": Path(args.report),
    }
    for name, path in paths.items():
        if not path.is_file():
            print(f"verify: missing {name}: {path}", file=sys.stderr)
            return 2

    recomputed = canonical_json(
        build_report(
            paths["corpus"],
            {"production": paths["production"], "strict_baseline": paths["strict"]},
        )
    )
    committed = paths["report"].read_text(encoding="utf-8")
    if recomputed == committed:
        print("verify: report matches recomputation from committed inputs")
        return 0
    print("verify: MISMATCH — committed report differs from recomputation", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
