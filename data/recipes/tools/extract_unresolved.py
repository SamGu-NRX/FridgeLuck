#!/usr/bin/env python3
"""Extract the unresolved-quantity worklist from data/recipes/corpus.jsonl.

Every ingredient line whose qty.kind is "unknown" (grams null) is grouped by
(ingredient name, unit) and counted. The result is the exact worklist for the
cited conversion table (data/recipes/conversions.json): one row per
(ingredient, unit) conversion covers every line in this list.

Optionally cross-matches each pair against a conversions table (the suite's
fixture table or the corpus-side one) to report which pairs a table already
covers, so coverage is reproducible from the table alone:

    python3 data/recipes/tools/extract_unresolved.py \
        [--conversions PATH] [--out PATH]

--conversions accepts either suite shape ({"conversions": {...}}) or a flat
mapping / list of rows; a pair is covered when some row matches the line's
ingredient name and unit (case-insensitive).
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"


def rows_from_table(data: Any) -> list[dict[str, Any]]:
    """Normalize any conversions-table shape to a list of row objects."""
    if isinstance(data, dict):
        data = data.get("conversions", data)
    if isinstance(data, dict):  # ref_id -> row
        return [dict(row, id=ref) if isinstance(row, dict) else {"id": ref, "grams_per_unit": row}
                for ref, row in data.items()]
    if isinstance(data, list):
        return [row for row in data if isinstance(row, dict)]
    return []


def pair_is_covered(name: str, unit: str, rows: list[dict[str, Any]]) -> str | None:
    """Return the covering row id, or None. Case-insensitive name+unit match."""
    key = (name.strip().lower(), str(unit).strip().lower())
    for row in rows:
        r_name = str(row.get("ingredient", row.get("name", ""))).strip().lower()
        r_unit = str(row.get("unit", "")).strip().lower()
        if r_name == key[0] and r_unit == key[1]:
            return str(row.get("id", "?"))
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--corpus", type=Path, default=CORPUS)
    ap.add_argument("--conversions", type=Path, default=None,
                    help="conversions table to cross-match against (suite or corpus-side)")
    ap.add_argument("--out", type=Path, default=None, help="write the worklist JSON here")
    args = ap.parse_args()

    pairs: Counter[tuple[str, str]] = Counter()
    recipes_with: Counter[str] = Counter()
    total_lines = 0
    for raw in args.corpus.read_bytes().split(b"\n"):
        if not raw.strip():
            continue
        recipe = json.loads(raw.decode("utf-8"))
        for line in recipe.get("ingredients", []):
            if not isinstance(line, dict):
                continue
            total_lines += 1
            qty = line.get("qty") or {}
            if qty.get("kind") == "unknown":
                name = str(line.get("name", "?")).strip()
                unit = str(qty.get("unit", "")).strip()
                pairs[(name, unit)] += 1
                recipes_with[recipe.get("id", "?")] += 1

    table_rows: list[dict[str, Any]] = []
    if args.conversions:
        table_rows = rows_from_table(json.loads(args.conversions.read_text()))

    worklist = [
        {"ingredient": name, "unit": unit, "lines": count,
         "covered_by": pair_is_covered(name, unit, table_rows)}
        for (name, unit), count in sorted(pairs.items(), key=lambda kv: (-kv[1], kv[0]))
    ]
    report = {
        "total_lines": total_lines,
        "unresolved_lines": sum(pairs.values()),
        "distinct_pairs": len(pairs),
        "recipes_affected": len(recipes_with),
        "pairs": worklist,
    }
    text = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.out:
        args.out.write_text(text)
        print(f"wrote {args.out}")
    covered = sum(p["lines"] for p in worklist if p["covered_by"])
    print(f"lines: {report['unresolved_lines']}/{total_lines} unresolved, "
          f"{len(pairs)} distinct (ingredient, unit) pairs, "
          f"{report['recipes_affected']} recipes affected")
    if args.conversions:
        print(f"cross-match vs {args.conversions.name}: "
              f"{covered}/{report['unresolved_lines']} lines already covered")
    for entry in worklist:
        mark = f" [covered by {entry['covered_by']}]" if entry["covered_by"] else ""
        print(f"  {entry['lines']:3d}  {entry['ingredient']} [{entry['unit']}]{mark}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
