#!/usr/bin/env python3
"""Inspect the bundled recipe catalog (apps/ios/Resources/data.json) for Part 1.

data.json format (verified on alpha 2e77938):
- top level: {"ingredients": {id: [name, kcal, protein, carbs, fat, fiber, sugar,
  sodium_g_per_100g, typical_unit, storage_tip]}, "recipes": [...]}
- each recipe is positional: [id, title, minutes, servings,
  main_ingredient_lines, pantry_lines, instructions, asset_id]
  where the two line lists are [[ingredient_id, grams], ...].

This tool decodes it read-only and dumps a workable analysis file (titles,
minutes, servings, ingredient names + grams, per-serving sodium from the
bundled ingredient nutrition, instructions) plus BUNDLED-TITLES.txt used by
every writer to avoid colliding with bundled dish names.

Usage:
    python3 tools/bundled.py --dump /tmp/bundled-recipes.json
    python3 tools/bundled.py --titles        # refresh BUNDLED-TITLES.txt
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import originals_common as oc  # noqa: E402

# positional recipe field indexes
R_ID, R_TITLE, R_MINUTES, R_SERVINGS, R_MAIN, R_PANTRY, R_INSTR, R_ASSET = range(8)


def decode():
    data = json.loads(oc.bundled_data_json_path().read_text())
    ings = {
        iid: {
            "name": v[0],
            "kcal_per_100g": v[1], "protein_g": v[2], "carbs_g": v[3],
            "fat_g": v[4], "fiber_g": v[5], "sugar_g": v[6],
            "sodium_mg_per_100g": round(v[7] * 1000.0),  # stored as g/100g
            "typical_unit": v[8], "storage_tip": v[9],
        }
        for iid, v in data["ingredients"].items()
    }
    return data, ings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dump", metavar="PATH", help="write the decoded analysis JSON")
    ap.add_argument("--titles", action="store_true", help="refresh BUNDLED-TITLES.txt")
    args = ap.parse_args()

    data, ings = decode()
    out = []
    for rec in data["recipes"]:
        lines = []
        sodium = 0.0
        kcal = 0.0
        for section in (rec[R_MAIN], rec[R_PANTRY]):
            for iid_s, grams in section:
                iid = str(iid_s)
                ing = ings.get(iid, {"name": f"#{iid}", "sodium_mg_per_100g": 0,
                                     "kcal_per_100g": 0})
                lines.append({"ingredient_id": iid, "name": ing["name"],
                              "grams": grams,
                              "sodium_mg_per_100g": ing["sodium_mg_per_100g"]})
                sodium += ing["sodium_mg_per_100g"] * grams / 100.0
                kcal += ing["kcal_per_100g"] * grams / 100.0
        servings = rec[R_SERVINGS] or 2
        out.append({
            "bundled_id": rec[R_ID],
            "title": rec[R_TITLE],
            "minutes": rec[R_MINUTES],
            "servings": servings,
            "sodium_mg_per_serving": round(sodium / servings, 1),
            "kcal_per_serving_bundled_math": round(kcal / servings, 1),
            "ingredients": lines,
            "instructions": rec[R_INSTR],
        })

    n_named = sum(1 for o in out if o["title"])
    print(f"decoded {len(out)} bundled recipes ({n_named} with titles), "
          f"{len(ings)} core ingredients")

    if args.dump:
        Path(args.dump).write_text(json.dumps(
            {"ingredients": ings, "recipes": out}, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {args.dump}")

    if args.titles:
        target = oc.originals_dir() / "BUNDLED-TITLES.txt"
        lines = ["# Bundled catalog dish names (alpha 2e779381bb39) - avoid these exact",
                 "# names for original recipes; run tools/bundled.py --titles to refresh."]
        for o in out:
            lines.append(f"{o['bundled_id']}\t{o['title']}\t{o['minutes']}min")
        target.write_text("\n".join(lines) + "\n")
        print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
