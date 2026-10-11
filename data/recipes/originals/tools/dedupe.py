#!/usr/bin/env python3
"""Cross-part and against-bundled title dedupe for the originals corpus.

Two layers:
1. exact duplicate of normalize_title() across all parts (hard error);
2. near-duplicate similarity vs other originals and vs the bundled catalog
   (soft warnings, so a writer sees them before pushing).

normalize_title strips punctuation, lowercases, and drops booster words
("easy", "quick", "healthy", ...), so "Easy Healthy Chicken Soup" collides
with "chicken soup" - the intended behaviour for a corpus that must not
publish the same dish twice.

Usage: python3 tools/dedupe.py [--threshold 0.82]
"""
from __future__ import annotations

import argparse
import difflib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import originals_common as oc  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--threshold", type=float, default=0.82,
                    help="SequenceMatcher ratio above which titles are near-duplicates")
    args = ap.parse_args()

    originals: list[tuple[str, str, str]] = []  # (part, id, normalized title)
    hard = 0
    seen: dict[str, tuple[str, str]] = {}
    for part in sorted(oc.PARTS):
        recipes, bad = oc.discover_recipes(part)
        for path, r in recipes:
            key = oc.normalize_title(str(r.get("title", "")))
            if not key:
                continue
            originals.append((part, r["id"], key))
            if key in seen:
                print(f"DUPLICATE title {key!r}: {seen[key][0]}/{seen[key][1]} "
                      f"and {part}/{r['id']}")
                hard += 1
            else:
                seen[key] = (part, r["id"])

    # bundled catalog titles for near-duplicate awareness
    bundled = []
    try:
        data = json.loads(oc.bundled_data_json_path().read_text())
        bundled = [oc.normalize_title(str(rec[1])) for rec in data["recipes"]]
    except Exception as exc:  # noqa: BLE001 - titles are best-effort
        print(f"(bundled titles unavailable: {exc})")

    soft = 0
    for part, rid, key in originals:
        for other_part, other_id, other_key in originals:
            if (other_part, other_id) >= (part, rid):
                continue
            if key != other_key and key and other_key and \
                    difflib.SequenceMatcher(None, key, other_key).ratio() > args.threshold:
                print(f"near-duplicate: {part}/{rid} ~ {other_part}/{other_id} "
                      f"({key!r} ~ {other_key!r})")
                soft += 1
        for b in bundled:
            if key and b and difflib.SequenceMatcher(None, key, b).ratio() > args.threshold:
                print(f"near-duplicate vs bundled: {part}/{rid} ({key!r}) ~ bundled {b!r}")
                soft += 1

    print(f"dedupe: {len(originals)} originals, {hard} exact-duplicate titles, "
          f"{soft} near-duplicate warning(s)")
    return 1 if hard else 0


if __name__ == "__main__":
    raise SystemExit(main())
