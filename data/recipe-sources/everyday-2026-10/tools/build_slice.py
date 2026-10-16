#!/usr/bin/env python3
"""Build converted-144.jsonl: PR #144's legacy rows 167-327 as RS v1 rewrites.

Mechanical pieces (ids, ingredient lines with legacy gram weights, category,
cuisine, meal slots, minutes, servings) come from legacy-144.json and
overrides/categories.json. Cook-facing text (title, steps) comes from the
authored fragments in overrides/144-*.json. See overrides/BRIEF.md for the
text rules.

Run:  python3 tools/build_slice.py [--slice-dir DIR]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REHEAT_TEXT = re.compile(r"\bre-?heat\w*|\bre-?warm\w*", re.IGNORECASE)

CATEGORY_SLOTS = {
    "breakfasts": ["breakfast"],
    "packed-lunches": ["lunch"],
    "sides-salads": ["lunch", "dinner"],
    "20-minute-dinners": ["dinner"],
    "budget-student-pantry": ["dinner", "lunch"],
    "high-protein": ["dinner", "lunch"],
    "vegetarian-vegan-mains": ["dinner"],
    "batch-leftovers": ["dinner", "lunch"],
}


# Legacy vocab display names re-labelled to the canonical forms the recipe
# text and the whitelist use. Labels only — legacy source-stated grams are
# kept exactly as given.
LEGACY_NAME_CANON = {
    "rice": "cooked rice",
    "bell_pepper": "red bell pepper",
    "green_onion": "green onions",
    "sweet_potato": "sweet potatoes",
    "frozen_peas": "green peas",
    "canned_tuna": "canned light tuna",
}

# Step-text normalizations paired with the canonical names above: the
# whitelist phrase "canned tuna" must not appear in text once the line is
# "canned light tuna" (the step-food rule checks phrase containment).
STEP_TEXT_CANON = {
    "canned tuna": "canned light tuna",
}


def load_fragments(overrides_dir: Path) -> dict[int, dict]:
    merged: dict[int, dict] = {}
    for path in sorted(overrides_dir.glob("144-*.json")):
        frag = json.loads(path.read_text(encoding="utf-8"))
        for rid, rec in frag.items():
            merged[int(rid)] = rec
    return merged


# Legacy fragments used informal FSIS class names; the RS linter only accepts
# the FSIS names (egg, flesh_fish, meat_ground, meat_poultry, leftovers).
SAFETY_CLASS_CANON = {"eggs": "egg", "poultry": "meat_poultry",
                      "ground_beef": "meat_ground", "seafood": "flesh_fish"}
# FSIS minimum for meat_poultry. A check labelled meat_poultry below 165 °F
# cannot name poultry; reclassify it by the recipe's actual protein so the
# class agrees with the endpoint the step text states.
POULTRY_MIN_F = 165
PROTEIN_FISH = ("salmon", "fish", "tuna", "shrimp")


def fix_safety(safety: dict, ingredient_names: list[str]) -> dict:
    cls = SAFETY_CLASS_CANON.get(str(safety.get("class")), safety.get("class"))
    temp = safety.get("temp_f")
    if cls == "meat_poultry" and isinstance(temp, (int, float)) and temp < POULTRY_MIN_F:
        joined = " ".join(ingredient_names).lower()
        # word-boundary match; "fish sauce" is a seasoning, not the endpoint's protein
        fish_re = r"\b(?:" + "|".join(PROTEIN_FISH) + r")\b"
        fish_names = re.sub(r"\bfish sauce\b", " ", joined)
        if re.search(fish_re, fish_names):
            cls = "flesh_fish"
        elif "ground" in joined:
            cls = "meat_ground"
        elif "egg" in joined:
            cls = "egg"
    safety["class"] = cls
    return safety


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--slice-dir", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args()
    d = args.slice_dir
    legacy = json.loads((d / "legacy-144.json").read_text(encoding="utf-8"))
    vocab = {int(k): str(v[0]) for k, v in legacy["ingredients"].items()}
    categories = json.loads((d / "overrides" / "categories.json").read_text(encoding="utf-8"))
    fragments = load_fragments(d / "overrides")

    rows = [r for r in legacy["recipes"] if 167 <= r[0] <= 327]
    problems: list[str] = []
    out: list[dict] = []
    for row in rows:
        rid, _title, minutes, servings, ings, _tags, _text, _x = row[:8]
        rec = fragments.get(rid)
        if rec is None:
            problems.append(f"legacy {rid}: no override fragment")
            continue
        cat, cuisine = categories[str(rid)]
        if cat not in CATEGORY_SLOTS:
            problems.append(f"legacy {rid}: unknown category {cat!r}")
            continue
        ing_names = [LEGACY_NAME_CANON.get(str(vocab[i]), str(vocab[i])) for i, _g in ings]
        steps = []
        for s in rec.get("steps", []):
            text = str(s.get("text", "")).strip()
            for legacy, canon in STEP_TEXT_CANON.items():
                text = text.replace(legacy, canon)
            step = {"text": text}
            if isinstance(s.get("safety"), dict):
                step["safety"] = fix_safety(s["safety"], ing_names)
            if REHEAT_TEXT.search(step["text"]):
                step["reheat"] = True
            steps.append(step)
        if not steps:
            problems.append(f"legacy {rid}: empty steps")
            continue
        out.append({
            "rs_version": "1",
            "id": f"fl-everyday-{rid - 66:04d}",
            "title": str(rec.get("title", "")).strip(),
            "cuisine": cuisine,
            "meal_slots": CATEGORY_SLOTS[cat],
            "minutes": minutes,
            "servings": servings,
            "ingredients": [
                {"name": LEGACY_NAME_CANON.get(str(vocab[i]), str(vocab[i])),
                 "qty": {"kind": "source_grams", "grams": g}}
                for i, g in ings
            ],
            "steps": steps,
            "source_ref": f"everyday-144-{rid}",
            "claims": [],
            "category": cat,
        })

    ids = [r["id"] for r in out]
    if len(set(ids)) != len(ids):
        problems.append("duplicate ids in output")
    if problems:
        for p in problems:
            print(f"BUILD PROBLEM: {p}", file=sys.stderr)
        return 1
    target = d / "converted-144.jsonl"
    with target.open("w", encoding="utf-8") as fh:
        for r in out:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {len(out)} recipes to {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
