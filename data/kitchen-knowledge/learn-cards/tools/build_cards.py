#!/usr/bin/env python3
"""Assemble cards/<id>.json and index.json from prose + universe + nutrition.

Reads:
  tools/universe.json        — ids, display names, isCore, frequencies
  tools/nutrition_out.json   — emitted nutritionPer100g blocks (None = refused)
  tools/prose/<id>.json      — per-card authored content (category, sections,
                               substitutions, sources)

Writes:
  cards/<id>.json, index.json
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
PROSE = os.path.join(HERE, "prose")
RETRIEVED = "2026-10-11"

USDA_SOURCE = {
    "title": "USDA FoodData Central — SR Legacy release 2018-04",
    "publisher": "U.S. Department of Agriculture, Agricultural Research Service",
    "url": "https://fdc.nal.usda.gov/download-datasets/",
    "retrieved": RETRIEVED,
    "licence": "Public domain (U.S. government work)",
    "notes": "Final frozen SR Legacy release; per-100 g values pulled from the "
             "CSV download and matched to the FDC id in nutritionPer100g.fdcId.",
}

def main():
    universe = json.load(open(os.path.join(HERE, "universe.json")))
    blocks = json.load(open(os.path.join(HERE, "nutrition_out.json")))["blocks"]
    cards_dir = os.path.join(ROOT, "cards")
    os.makedirs(cards_dir, exist_ok=True)

    cards, missing_prose = [], []
    for cid, meta in universe["cards"].items():
        ppath = os.path.join(PROSE, f"{cid}.json")
        if not os.path.exists(ppath):
            missing_prose.append(cid)
            continue
        prose = json.load(open(ppath, encoding="utf-8"))
        nut = blocks.get(cid)
        sources = dict(prose.get("sources") or {})
        if nut is not None and "s-usda" not in sources:
            sources["s-usda"] = dict(USDA_SOURCE,
                                     notes=f"{USDA_SOURCE['notes']} Row: "
                                           f"fdcId {nut['fdcId']} "
                                           f"({nut['fdcDescription']}).")
        storage = dict(prose["sections"]["storage"])
        storage.setdefault("citations", [])
        storage["foodSafetyRef"] = {
            "path": "data/food-safety/rules.json",
            "note": storage.pop("note", "storage and shelf-life guidance for "
                                        "this ingredient lives in the food-safety "
                                        "rulebook (PR #97)"),
        }
        data = {
            "id": cid,
            "displayName": meta["displayName"],
            "isCore": meta["isCore"],
            "category": prose["category"],
            "sections": prose["sections"] | {"storage": storage},
            "substitutions": prose.get("substitutions", []),
        }
        if nut is not None:
            data["nutritionPer100g"] = nut
        data["sources"] = sources
        card = {"schemaVersion": 1, "kind": "learn-card",
                "retrieved": RETRIEVED, "data": data}
        with open(os.path.join(cards_dir, f"{cid}.json"), "w", encoding="utf-8") as f:
            json.dump(card, f, indent=1, ensure_ascii=False)
            f.write("\n")
        cards.append({
            "id": cid,
            "displayName": meta["displayName"],
            "isCore": meta["isCore"],
            "category": prose["category"],
            "frequencyInBundledRecipes": meta["frequencyInBundledRecipes"],
            "fdcId": nut["fdcId"] if nut else None,
        })

    if missing_prose:
        print(f"NOTE: prose not yet written for {len(missing_prose)}: {missing_prose}")

    no_nut = sorted(c["id"] for c in cards if c["fdcId"] is None)
    summary = universe["summary"]
    coverage = {
        "coreIngredients": summary["coreCards"],
        "bundledDistinctIngredients": summary["bundledDistinctIngredientIds"],
        "cardsWritten": len(cards),
        "seedCorpusDistinctNames": summary["seedDistinctNames"],
        "missingNutrition": no_nut,
        "note": (
            "Coverage = the app's 50 core ingredients plus every distinct "
            "ingredient in the rights-clear seed-corpus recipes "
            f"({summary['seedDistinctNames']} distinct names merged to 66 extra "
            "cards; 116 total). Bundled data.json recipes reference 47 distinct "
            "ids, all core. 108 cards carry nutrition from SR Legacy release "
            "2018-04; 8 speciality ingredients have no honest SR Legacy row and "
            "ship without nutritionPer100g rather than with guessed values."
        ),
    }
    index = {"schemaVersion": 1, "kind": "learn-card-index",
             "retrieved": RETRIEVED,
             "data": {"cards": cards, "coverage": coverage}}
    with open(os.path.join(ROOT, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"built {len(cards)} cards; no nutrition for {no_nut}")

if __name__ == "__main__":
    main()
