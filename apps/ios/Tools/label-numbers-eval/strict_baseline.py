#!/usr/bin/env python3
"""Strict tool baseline for the label-numbers corpus.

A deliberately rigid, single-purpose extractor used only as a comparison arm:
line-anchored patterns, no column joining, no corruption tolerance, no
fallbacks. Its purpose is to show how much of the production parser's score
comes from tolerant parsing versus plain line extraction. It writes
`reports/strict_predictions.jsonl` in the same shape as the Swift replay
predictions so `score_report.py` can score both arms identically.

Patterns (documented because strictness is the whole point):
  serving size            ^Serving size (.+)$           verbatim capture
  calories                ^Calories[ ]+([0-9][0-9,]*)   first number on the line
  servings per container  ^About ([0-9]+) servings per container$  strict order

Anything else is an abstention. The output mirrors ReplayPrediction in
SwiftReplay so the scorer treats both arms symmetrically.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SERVING_SIZE_RE = re.compile(r"^Serving size (.+)$")
CALORIES_RE = re.compile(r"^Calories +([0-9][0-9,]*)")
SERVINGS_RE = re.compile(r"^About ([0-9]+) servings per container$")


def extract(lines: list[str]) -> dict:
    serving_size = None
    calories = None
    servings = None
    for line in lines:
        text = line.strip()
        if serving_size is None:
            m = SERVING_SIZE_RE.match(text)
            if m:
                serving_size = m.group(1).strip()
        if calories is None:
            m = CALORIES_RE.match(text)
            if m:
                calories = float(m.group(1).replace(",", ""))
        if servings is None:
            m = SERVINGS_RE.match(text)
            if m:
                servings = float(m.group(1))
    parsed = calories is not None
    return {
        "keyword_positive": True,  # strict arm has no keyword gate
        "parsed": parsed,
        "calories_per_serving": calories if parsed else None,
        "serving_size": serving_size if parsed else None,
        "servings_per_container": servings if parsed else None,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--corpus", default="corpus/labels.jsonl")
    ap.add_argument("--out", default="reports/strict_predictions.jsonl")
    args = ap.parse_args()

    out_lines = []
    with open(args.corpus, encoding="utf-8") as fh:
        for raw in fh:
            if not raw.strip():
                continue
            record = json.loads(raw)
            result = extract(record["lines"])
            out_lines.append(
                json.dumps(
                    {
                        "record_id": record["record_id"],
                        "family": record["family"],
                        "variant_kind": record["variant_kind"],
                        **result,
                    },
                    sort_keys=True,
                )
            )
    out = "\n".join(out_lines) + ("\n" if out_lines else "")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(out, encoding="utf-8")
    print(f"wrote {len(out_lines)} strict predictions to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
