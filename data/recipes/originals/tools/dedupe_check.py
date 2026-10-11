#!/usr/bin/env python3
"""Near-duplicate detection across the originals corpus.

Flags title token overlap AND ingredient overlap between recipes (within a part
or across parts). Used by writers per part and by the join step corpus-wide.

Usage:
    python3 tools/dedupe_check.py --all
    python3 tools/dedupe_check.py --part south-asian
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import originals_common as oc  # noqa: E402

TITLE_J = 0.60
INGR_J = 0.50
TITLE_J_STRICT = 0.50


def jaccard(a: set, b: set) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--part", default=None)
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()
    if not args.all and not args.part:
        ap.error("pass --part <name> or --all")

    parts = sorted(oc.PARTS) if args.all else [args.part]
    items = []
    for p in parts:
        recipes, _bad = oc.discover_recipes(p)
        for path, r in recipes:
            items.append({
                "part": p, "id": r["id"], "title": r.get("title", ""),
                "tokens": set(oc.normalize_title(r.get("title", ""))),
                "ingredients": {str(ln.get("name", "")).strip().lower()
                                for ln in r.get("ingredients", [])},
            })

    flags = []
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            a, b = items[i], items[j]
            tj = jaccard(a["tokens"], b["tokens"])
            ij = jaccard(a["ingredients"], b["ingredients"])
            same_title = bool(a["tokens"]) and a["tokens"] == b["tokens"]
            if (tj >= TITLE_J and ij >= INGR_J) or (same_title and tj >= TITLE_J_STRICT):
                flags.append({
                    "a": f"{a['part']}/{a['id']}", "b": f"{b['part']}/{b['id']}",
                    "title_a": a["title"], "title_b": b["title"],
                    "title_jaccard": round(tj, 3), "ingredient_jaccard": round(ij, 3),
                })

    for f in flags:
        print(f"DUP {f['a']} <-> {f['b']}: title {f['title_jaccard']}, "
              f"ingredients {f['ingredient_jaccard']}  ({f['title_a']!r} vs {f['title_b']!r})")
    print(f"{len(flags)} flag(s)")
    out = oc.originals_dir() / "DEDUPE-FLAGS.json"
    out.write_text(json.dumps({"flags": flags}, indent=2) + "\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
