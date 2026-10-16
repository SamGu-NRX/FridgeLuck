#!/usr/bin/env python3
"""Record >40% per-serving kcal moves between two published recipe bundles.

When a vocabulary revision resolves ingredient keys that previously shipped
without per-100g nutrition, recipes can move materially. Every move of more
than 40 percent must be recorded in data/recipe-bundle/nutrition-changes-2026-10.json
naming the vocabulary change that caused it.
validate_bundle.py --previous <old bundle> --changes <this file> enforces it.

The cause is computed honestly. A recipe's entry lists every traceable cause
among these kinds:

1. resolved keys  — keys in the recipe's lines that gained a per-100g row
   between the previous and current vocabulary;
2. re-sourced rows — keys in the recipe's lines whose per-100g row was
   replaced between the two vocabulary revisions (old vs new row kcal cited,
   so a correction that changes an existing row is recorded, not just a
   first resolution);
3. corpus amount fixes — the recipe was rewritten by a committed fix packet
   under data/recipes/fixes/ (--fixes-dir); the cause names the packet file
   and the fix record id.

If a swing cannot be traced to any of these, the tool fails closed instead of
writing an unexplained exemption.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT_DEFAULT = REPO / "data/recipe-bundle/nutrition-changes-2026-10.json"
VOCAB = REPO / "data/ingredients/vocabulary.json"
FIXES_DIR = REPO / "data/recipes/fixes"
DRIFT_THRESHOLD = 0.40


def kcal_swing(old: float, new: float) -> float:
    if old == 0:
        return 0.0 if new == 0 else float("inf")
    return abs(new - old) / old


def per100_changed(old: dict | None, new: dict | None) -> bool:
    """True when a key's per-100g row was replaced (either direction)."""
    if old is None or new is None:
        return False
    return old != new


def fix_packets(fixes_dir: Path) -> dict[str, list[dict]]:
    """catalog_id -> [{file, fix_id}] from committed fix packets."""
    if not fixes_dir.is_dir():
        return {}
    out: dict[str, list[dict]] = {}
    for path in sorted(fixes_dir.glob("*.json")):
        packet = json.loads(path.read_text(encoding="utf-8"))
        fixes = packet.get("fixes") if isinstance(packet, dict) else None
        if not isinstance(fixes, list):
            continue
        for fix in fixes:
            rid = fix.get("catalog_id")
            if rid:
                out.setdefault(rid, []).append(
                    {"file": f"data/recipes/fixes/{path.name}",
                     "fix_id": fix.get("id")})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--new", default=str(REPO / "data/recipes/build/recipes-v2.json"),
                    help="newly compiled bundle")
    ap.add_argument("--previous", required=True, help="previously published bundle")
    ap.add_argument("--previous-vocab", required=True,
                    help="vocabulary.json as committed with the previous bundle")
    ap.add_argument("--fixes-dir", default=str(FIXES_DIR),
                    help="committed corpus fix packets (cause kind 3)")
    ap.add_argument("--vocab", default=str(VOCAB),
                    help="current vocabulary.json (the revision being recorded)")
    ap.add_argument("--out", default=str(OUT_DEFAULT))
    ap.add_argument("--previous-note", required=True,
                    help="provenance of the previous bundle, e.g. the commit sha it ships in")
    args = ap.parse_args()

    new = json.load(open(args.new))
    prev = json.load(open(args.previous))
    cur_vocab = {e["key"]: e for e in json.load(open(args.vocab))["entries"]}
    prev_vocab = {e["key"]: e for e in json.load(open(args.previous_vocab))["entries"]}
    fixes = fix_packets(Path(args.fixes_dir))

    # Cause kind 1: keys that gained a per-100g row between the revisions.
    resolved = {
        k: cur_vocab[k] for k in cur_vocab
        if cur_vocab[k].get("per_100g") is not None
        and prev_vocab.get(k, {}).get("per_100g") is None
    }
    # Cause kind 2: keys whose per-100g row was re-sourced (row replaced).
    resourced = {
        k: (prev_vocab[k], cur_vocab[k]) for k in cur_vocab
        if per100_changed(prev_vocab.get(k, {}).get("per_100g"),
                          cur_vocab[k].get("per_100g"))
        and k not in resolved
    }
    print(f"vocabulary keys resolved between revisions: {len(resolved)}")
    print(f"vocabulary keys re-sourced between revisions: {len(resourced)}")
    print(f"corpus fix packets cover {len(fixes)} catalog ids")

    prev_n = {r["catalog_id"]: r["nutrition_per_serving"] for r in prev["recipes"]}
    entries = []
    unexplained = []
    for recipe in new["recipes"]:
        rid = recipe["catalog_id"]
        old_n = prev_n.get(rid)
        if old_n is None:
            continue
        n = recipe["nutrition_per_serving"]
        swing = kcal_swing(old_n["kcal"], n["kcal"])
        if swing <= DRIFT_THRESHOLD:
            continue
        line_keys = {line["key"] for line in recipe["ingredients"]}
        causes = []
        hit_resolved = sorted(k for k in line_keys if k in resolved)
        if hit_resolved:
            detail = ", ".join(
                f"{k} (fdc {resolved[k]['fdc_id']})" for k in hit_resolved)
            causes.append(f"keys in this recipe resolved to per-100g rows "
                          f"in this revision: {detail}")
        hit_resourced = sorted(k for k in line_keys if k in resourced)
        for k in hit_resourced:
            old_e, new_e = resourced[k]
            causes.append(
                f"per-100g row re-sourced in this revision: {k} "
                f"(fdc {old_e.get('fdc_id')} {old_e.get('per_100g', {}).get('kcal')} kcal/100g "
                f"-> fdc {new_e.get('fdc_id')} {new_e.get('per_100g', {}).get('kcal')} kcal/100g)")
        for fix in fixes.get(rid, []):
            causes.append(f"corpus amount fix {fix['file']} fix id {fix['fix_id']}")
        if not causes:
            unexplained.append(rid)
            continue
        entries.append({
            "catalog_id": rid,
            "old_kcal": old_n["kcal"],
            "new_kcal": n["kcal"],
            "vocabulary_change": "; ".join(causes),
        })
    if unexplained:
        raise SystemExit(
            "kcal swings with no resolved vocabulary key, re-sourced row, or "
            "corpus fix behind them: "
            f"{sorted(unexplained)} — investigate before exempting")

    entries.sort(key=lambda e: e["catalog_id"])
    doc = {
        "note": "Recipes whose per-serving kcal moved more than 40 percent against the "
                "previously published bundle, with the vocabulary change or corpus fix that "
                "caused each move. Recorded by data/recipes/tools/record_nutrition_changes.py; "
                "enforced by validate_bundle.py --previous --changes.",
        "policy": "A >40% kcal move between published bundles must be exempted here with "
                  "the vocabulary change that caused it; exemption entries must reproduce "
                  "both kcal values.",
        "previous_bundle": args.previous_note,
        "threshold": DRIFT_THRESHOLD,
        "entries": entries,
    }
    Path(args.out).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {args.out}: {len(entries)} exempted kcal moves "
          f"(of {len(new['recipes'])} recipes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
