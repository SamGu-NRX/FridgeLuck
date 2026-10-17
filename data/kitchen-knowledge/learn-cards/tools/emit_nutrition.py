#!/usr/bin/env python3
"""Emit nutritionPer100g blocks from the curated fdc_map.csv.

Reads the SR Legacy CSV download (set SR_DIR below, or pass as argv[1]) and
tools/fdc_map.csv; writes tools/nutrition_out.json mapping card_id ->
nutritionPer100g block (None where the map has no fdc_id).

Nutrient ids verified against nutrient.csv in this download (see README):
  1008 energy kcal, 1003 protein G, 1005 carbohydrate G, 2000 sugars G,
  1079 fiber G, 1004 fat G, 1258 saturated fat G, 1093 sodium MG,
  1092 potassium MG, 1087 calcium MG, 1089 iron MG, 1162 vitamin C MG,
  1106 vitamin A RAE UG, 1177 folate UG.
Note: 1104 in this download is Vitamin A in IU, NOT RAE. RAE is 1106.
"""
import csv
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SR_DEFAULT = "/tmp/sr_legacy/FoodData_Central_sr_legacy_food_csv_2018-04"
RELEASE = "SR Legacy release 2018-04 (final frozen SR Legacy release)"

NUTRIENT_IDS = {
    "1008": "energyKcal", "1003": "proteinG", "1005": "carbohydrateG",
    "2000": "sugarG", "1079": "fiberG", "1004": "fatG", "1258": "saturatedFatG",
    "1093": "sodiumMg", "1092": "potassiumMg", "1087": "calciumMg",
    "1089": "ironMg", "1162": "vitaminCMg", "1106": "vitaminARaeMcg",
    "1177": "folateMcg",
}

def r2(x):
    r = round(x + 0.0, 2)
    return int(r) if r == int(r) else r

def main():
    sr = sys.argv[1] if len(sys.argv) > 1 else SR_DEFAULT
    descriptions = {}
    with open(os.path.join(sr, "food.csv"), newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            descriptions[int(row["fdc_id"])] = row["description"]
    values = {}  # fdc_id -> {key: value}
    want = set(int(k) for k in NUTRIENT_IDS)
    with open(os.path.join(sr, "food_nutrient.csv"), newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            fid = int(row["fdc_id"])
            nid = int(row["nutrient_id"])
            if nid in want and fid in descriptions:
                v = row["amount"]
                if v not in ("", None, "NA"):
                    values.setdefault(fid, {})[NUTRIENT_IDS[str(nid)]] = float(v)

    out, missing = {}, []
    with open(os.path.join(HERE, "fdc_map.csv"), newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            cid = row["card_id"]
            fid_s = row["fdc_id"].strip()
            if not fid_s:
                out[cid] = None
                missing.append(cid)
                continue
            fid = int(fid_s)
            desc = descriptions.get(fid)
            if desc is None:
                raise SystemExit(f"{cid}: fdc_id {fid} not in food.csv")
            nv = values.get(fid, {})
            if "energyKcal" not in nv:
                raise SystemExit(f"{cid}: fdc_id {fid} has no energy value")
            block = {
                "fdcId": fid,
                "fdcDescription": desc,
                "fdcDataType": "SR Legacy",
                "sourceId": "s-usda",
                "nutrients": {k: r2(v) for k, v in nv.items()},
            }
            out[cid] = block

    json.dump({"release": RELEASE, "blocks": out},
              open(os.path.join(HERE, "nutrition_out.json"), "w"), indent=1)
    print(f"emitted {sum(1 for v in out.values() if v)} blocks; "
          f"{len(missing)} without nutrition: {missing}")

if __name__ == "__main__":
    main()
