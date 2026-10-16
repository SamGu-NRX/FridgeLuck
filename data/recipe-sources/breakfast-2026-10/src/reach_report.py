#!/usr/bin/env python3
"""Pantry-reach analysis for the breakfast-2026-10 packet.

Answers the burst question with the project's own resolution semantics:
how many of the packet's 30 recipes can the ten named pantry fixtures
(evaluation/catalog-reach/pantries-v2.json) already cook?

Rules, reused unchanged from the project's reach tooling:
- Staples: STAPLE_KEYS from data/recipes/tools/compile_bundle.py — required
  lines never include them (compile_bundle flags the same keys
  `assumed_staple` when building bundle-v2).
- Pantry-item candidates: the exact written-name transforms of
  reach_report_v2._candidate_keys (lowercase, snake_case, naive plural
  folds) — no similarity guessing.
- Recipe-line identity: the app's own name-mappings surface -> vocabulary
  key (data/ingredients/name-mappings.json), the same mapping the catalog
  compiler uses. A required line is in a pantry when its key matches a
  pantry candidate key exactly.
- Tiers: `cookable_now` = every required line present (missing 0);
  `cookable_near` = at most NEAR_MATCH_MAX_MISSING = 2 required lines
  missing (the reach-v2 near tier).

Disclosed limits: this runs over the packet's RS records directly, not a
compiled bundle-v2, so it shares no code with reach_report_v2's bundle
loader; the ingredient->key step uses the app mappings, which is the same
canonical-identity space the bundle keys come from. A line whose surface
name does not resolve in name-mappings is required and always missing
(fail closed), and any such miss is disclosed per recipe.

Output: reach-report.json next to this packet's build-report.json, plus a
stdout summary. Deterministic; no network.
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
REPO = PKG.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO / "data" / "recipes" / "tools"))

PANTRIES = REPO / "evaluation" / "catalog-reach" / "pantries-v2.json"
NEAR_MATCH_MAX_MISSING = 2  # same near tier as reach_report_v2.py

# STAPLE_KEYS, quoted from data/recipes/tools/compile_bundle.py (overhaul
# spec 3.2) at this checkout. Re-declared verbatim rather than imported so
# the packet's reach numbers stay pinned even if the compiler's set moves.
STAPLE_KEYS = {
    "olive_oil", "vegetable_oil", "sunflower_oil", "coconut_oil", "sesame_oil",
    "salt", "black_pepper", "water", "sugar", "brown_sugar", "plain_flour",
    "all_purpose_flour", "butter", "soy_sauce", "lemon_juice", "white_wine_vinegar",
    "red_wine_vinegar", "apple_cider_vinegar", "rice_vinegar", "honey", "mustard",
    "chili_flakes", "smoked_paprika", "paprika", "dried_oregano", "oregano",
    "ground_cumin", "cumin", "coriander", "ground_corriander", "cinnamon",
    "bay_leaf", "stock_cube", "tomato_paste", "cornflour", "cornstarch",
    "garlic", "onion", "cooking_spray", "black_tea", "coffee", "sea_salt",
}


def candidate_keys(item: str) -> list[str]:
    """reach_report_v2._candidate_keys, quoted: exact written-name
    transforms only (lowercase, snake_case, naive plural folds)."""
    low = item.strip().lower()
    snake = low.replace("-", "_").replace(" ", "_")
    out = [low, snake]
    for base in (low, snake):
        if base.endswith("ies") and len(base) > 4:
            out.append(base[:-3] + "y")
        elif base.endswith("es") and len(base) > 3:
            out.append(base[:-2])
        elif base.endswith("s") and not base.endswith("ss") and len(base) > 2:
            out.append(base[:-1])
    seen: set[str] = set()
    return [c for c in out if not (c in seen or seen.add(c))]


def line_keys(line: dict, surface_map: dict) -> tuple[str | None, str | None]:
    """(vocabulary key, method) for a record's ingredient line, or
    (None, reason) when the surface name does not resolve."""
    surface = str(line["name"]).strip().lower()
    hit = surface_map.get(surface)
    if hit:
        return hit.get("key"), "name_mappings"
    # prep-strip'd surfaces ("parsley, chopped") are not in the mappings —
    # fold to the comma-stripped head, an exact written form, never a guess
    head = surface.split(",")[0].strip()
    hit = surface_map.get(head)
    if hit:
        return hit.get("key"), "comma_head"
    return None, "unresolved"


def main() -> int:
    records = [json.loads(line) for line in
               (PKG / "originals.jsonl").read_text().splitlines()
               if line.strip()]
    mappings = json.loads(
        (REPO / "data" / "ingredients" / "name-mappings.json").read_text())
    surface_map = mappings.get("mappings", mappings)
    pantries = json.loads(PANTRIES.read_text())["pantries"]

    # resolve every recipe line once
    per_recipe: dict[str, dict] = {}
    unresolved_lines: list[tuple[str, str]] = []
    for r in records:
        rid = r["id"]
        required: list[dict] = []
        for line in r["ingredients"]:
            key, method = line_keys(line, surface_map)
            if key is None:
                unresolved_lines.append((rid, line["name"]))
                required.append({"name": line["name"], "key": None,
                                 "staple": False, "method": "unresolved"})
                continue
            required.append({"name": line["name"], "key": key,
                             "staple": key in STAPLE_KEYS, "method": method})
        per_recipe[rid] = {"title": r["title"],
                           "lines": [x for x in required if not x["staple"]]}

    report_pantries = {}
    for p in pantries:
        pantry_keys = {k for item in p["items"]
                       for k in candidate_keys(item)}
        now, near = [], []
        missing_counter: Counter = Counter()
        for rid, info in per_recipe.items():
            missing = [x for x in info["lines"]
                       if x["key"] is None or x["key"] not in pantry_keys]
            if len(missing) == 0:
                now.append(rid)
            if len(missing) <= NEAR_MATCH_MAX_MISSING:
                near.append(rid)
            for x in missing:
                missing_counter[x["name"]] += 1
        report_pantries[p["name"]] = {
            "cookable_now": sorted(now),
            "cookable_now_count": len(now),
            "cookable_near": sorted(near),
            "cookable_near_count": len(near),
            "top_missing_ingredients": missing_counter.most_common(8),
        }

    blocked = sorted(rid for rid, info in per_recipe.items()
                     if any(x["key"] is None for x in info["lines"]))
    out = {
        "method": ("packet-local pantry reach over the ten named fixtures "
                   "(evaluation/catalog-reach/pantries-v2.json); staples = "
                   "compile_bundle.STAPLE_KEYS; pantry candidates = "
                   "reach_report_v2._candidate_keys exact transforms; line "
                   "identity = data/ingredients/name-mappings.json "
                   "(comma-head fold disclosed); exact = 0 required lines "
                   "missing, near = at most 2 (reach-v2 tiers); no "
                   "similarity guessing; unresolved lines fail closed"),
        "recipes": len(records),
        "pantries": report_pantries,
        "recipes_with_unresolved_required_line": blocked,
        "unresolved_lines": sorted(set(unresolved_lines)),
        "staple_source": "data/recipes/tools/compile_bundle.py STAPLE_KEYS",
    }
    (PKG / "reach-report.json").write_text(
        json.dumps(out, indent=1, ensure_ascii=False) + "\n")

    print(f"recipes: {len(records)}; pantries: {len(report_pantries)}")
    for name, r in report_pantries.items():
        print(f"  {name}: now {r['cookable_now_count']}, "
              f"near {r['cookable_near_count']}")
    if blocked:
        print(f"unresolved required lines in: {blocked}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
