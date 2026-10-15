#!/usr/bin/env python3
"""Scan the unresolved quantity lines for amounts stated IN the record.

The 217 qty.kind="unknown" lines carry no value and no unit. Before any
conversion row can annotate them, an amount must exist somewhere; the only
honest place left is the recipe's own step text ("Stir in 1 cup of
breadcrumbs"). This tool measures exactly that, deterministically:

  * every measure phrase (number + unit) in the recipe's steps,
  * attributed to an unknown ingredient line when a distinctive token of the
    line's name occurs in the phrase's local window,
  * classified: 0 mentions -> no in-record amount; 1 distinct amount ->
    annotatable with a cited conversion; several distinct amounts -> ambiguous,
    left unknown (conservative).

No corpus file is modified. Output is a JSON report plus a per-line listing:

    python3 data/recipes/tools/scan_inrecord_amounts.py [--out PATH]
"""

from __future__ import annotations

import argparse
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"

# number: 1, 1.5, 1/2, 1 1/2, 1-2, unicode vulgar fractions handled separately
_NUMBER = r"(?:\d+(?:\.\d+)?|\d+/\d+)"
_SP = r"[\s\u00a0]"
UNIT_PATTERNS: dict[str, str] = {
    "cup": r"cups?",
    "tbsp": r"(?:tbsp|tablespoons?)",
    "tsp": r"(?:tsp|teaspoons?)",
    "oz": r"(?:oz|ounces?)",
    "lb": r"(?:lbs?|pounds?)",
    "g": r"(?:g|grams?)",
    "ml": r"(?:ml|millilit(?:er|re)s?)",
    "can": r"(?:cans?|tins?)",
    "clove": r"cloves?",
    "slice": r"slices?",
    "sprig": r"sprigs?",
    "handful": r"handfuls?",
    "pinch": r"pinches?",
    "dash": r"dashes?",
    "pack": r"(?:packs?|packet s?)",
    "bunch": r"bunch(?:es)?",
    "stick": r"sticks?",
    "piece": r"(?:pieces?|whole)",
}
_MEASURE_RE = re.compile(
    rf"(?P<num>{_NUMBER})(?:{_SP}(?:to|-){_SP}(?P<num2>{_NUMBER}))?{_SP}(?P<unit>"
    + "|".join(UNIT_PATTERNS.values())
    + r")\b",
    re.IGNORECASE,
)
_VULGAR = {"½": "1/2", "¼": "1/4", "¾": "3/4", "⅓": "1/3", "⅔": "2/3", "⅛": "1/8"}
_STOP = {
    "a", "an", "the", "of", "and", "or", "with", "in", "for", "to", "plus",
    "fresh", "good", "ready", "whole", "large", "small", "medium", "ripe",
    "canned", "jarred", "dried", "ground", "chopped", "diced", "sliced",
    "drained", "peeled", "cubed", "toasted", "torn", "cut", "picked", "over",
    "finely", "thinly", "leaves", "sprigs", "woody", "ends", "snapped", "off",
    "reserved", "minced", "crushed", "halved", "segmented", "shaved", "chunked",
    "pitted", "trimmed", "washed", "lardons", "casing", "casings", "removed",
    "chicken", "beef", "pork", "milk", "tea", "bag", "chili", "green", "red",
}


def norm_text(s: str) -> str:
    for ch, repl in _VULGAR.items():
        s = s.replace(ch, f" {repl} ")
    return unicodedata.normalize("NFKC", s)


def parse_amount(num: str) -> float:
    if "/" in num:
        a, b = num.split("/")
        return float(a) / float(b)
    return float(num)


def name_tokens(name: str) -> list[str]:
    """Distinctive tokens of an ingredient name (prep clauses dropped)."""
    head = name.split(",")[0]
    toks = [t for t in re.findall(r"[a-z]+", head.lower()) if t not in _STOP]
    return toks or [t for t in re.findall(r"[a-z]+", head.lower())]


def scan_recipe(recipe: dict[str, Any]) -> list[dict[str, Any]]:
    steps_text = "\n".join(
        str(s.get("text", "")) for s in recipe.get("steps", []) if isinstance(s, dict)
    )
    ntext = norm_text(steps_text)
    matches = []
    for m in _MEASURE_RE.finditer(ntext):
        start = max(0, m.start() - 60)
        end = min(len(ntext), m.end() + 60)
        matches.append({
            "num": parse_amount(m.group("num")),
            "num2": parse_amount(m.group("num2")) if m.group("num2") else None,
            "unit": m.group("unit").lower(),
            "context": " ".join(ntext[start:end].split()),
        })
    out = []
    for line in recipe.get("ingredients", []):
        qty = line.get("qty") or {}
        if not (isinstance(line, dict) and qty.get("kind") == "unknown"):
            continue
        name = str(line.get("name", "?"))
        toks = name_tokens(name)
        hits = [
            mm for mm in matches
            if any(t in mm["context"].lower() for t in toks)
        ]
        amounts = {(mm["num"], mm["unit"]) for mm in hits}
        out.append({
            "recipe": recipe.get("id", "?"),
            "name": name,
            "tokens": toks,
            "n_mentions": len(hits),
            "distinct_amounts": sorted(amounts),
            "annotatable": len(amounts) == 1,
            "mentions": hits,
        })
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--corpus", type=Path, default=CORPUS)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()

    lines: list[dict[str, Any]] = []
    for raw in args.corpus.read_bytes().split(b"\n"):
        if raw.strip():
            lines.extend(scan_recipe(json.loads(raw.decode("utf-8"))))

    n = len(lines)
    none = sum(1 for e in lines if e["n_mentions"] == 0)
    one = sum(1 for e in lines if e["annotatable"])
    multi = n - none - one
    unit_mix = Counter(e["distinct_amounts"][0][1] for e in lines if e["annotatable"])
    pair_mix = Counter(
        (e["name"], e["distinct_amounts"][0][1]) for e in lines if e["annotatable"]
    )
    report = {
        "unknown_lines": n,
        "no_inrecord_amount": none,
        "annotatable_one_amount": one,
        "ambiguous_multiple": multi,
        "annotatable_units": dict(unit_mix.most_common()),
        "annotatable_pairs": [
            {"name": k[0], "unit": k[1], "lines": v}
            for k, v in pair_mix.most_common()
        ],
        "lines": lines,
    }
    text = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.out:
        args.out.write_text(text)
        print(f"wrote {args.out}")
    print(f"unknown lines: {n}; with in-record amount: {one + multi} "
          f"(unambiguous: {one}); no amount anywhere in record: {none}")
    print("annotatable units:", dict(unit_mix.most_common()))
    print("annotatable (name, unit) pairs:")
    for k, v in pair_mix.most_common():
        print(f"  {v:3d}  {k[0]} [{k[1]}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
