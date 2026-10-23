#!/usr/bin/env python3
"""Author the FoodSeg103 -> FridgeLuck catalog taxonomy mapping.

Writes taxonomy/foodseg103_to_catalog.csv with one row per FoodSeg103 class:

- semantic_kind: exact | coarse | ambiguous | unsupported (judgment, rationale column)
- target_ingredient_ids: semicolon-separated app ingredient ids (empty for unsupported)
- resolution_* columns: what the app's ACTUAL resolver does with the class name
  string (empirical, from resolution/app_resolution.py on the shipped USDA catalog)

Mapping judgment rules (documented in LICENSE-NOTES/report):
- exact: the app ingredient denotes the same food as the FoodSeg class
  (curated lexicon id, or USDA catalog id the app's resolver actually reaches).
- coarse: the app ingredient is a broader/different-prep shelf that the app's own
  lexicon style would accept (cf. fried_chicken -> Chicken, fish -> Salmon shelf).
- ambiguous: one class covers several app shelves or the resolution is semantically
  unreliable (e.g. "cheese butter" -> Cheese OR Butter; pork -> catalog "Pork Fat").
- unsupported: no app ingredient can correctly claim the class (dishes, snacks,
  drinks, and produce with no app shelf). These rows are kept and scored, never
  silently dropped.
"""

import csv
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESOLUTION = HERE.parent / "resolution"
PROBE = Path("/home/user/work/bench/resolver_probe_foodseg.json")

# {class_id: (kind, targets, rationale)}
JUDGMENT: dict[int, tuple[str, str, str]] = {
    1: ("unsupported", "", "Confection; no app shelf."),
    2: ("unsupported", "", "Dish (egg tart); dish-level, kept out of ingredient claims."),
    3: ("ambiguous", "10", "Fries vs Potato shelf: claiming Potato inflates raw-potato inventory; app has no fries shelf."),
    4: ("unsupported", "", "Confection; no app shelf."),
    5: ("unsupported", "", "Snack; no app shelf."),
    6: ("unsupported", "", "Snack; no app shelf."),
    7: ("unsupported", "", "Prepared dessert; no app shelf."),
    8: ("unsupported", "", "Prepared dessert; no app shelf."),
    9: ("ambiguous", "12;14", "One class covers two distinct app shelves (Cheese, Butter); unresolvable at class level."),
    10: ("unsupported", "", "Dish; no app shelf."),
    11: ("unsupported", "", "Beverage; outside the app's ingredient shelves."),
    12: ("unsupported", "", "Beverage; no app shelf."),
    13: ("unsupported", "", "Beverage; no app shelf."),
    14: ("unsupported", "", "Beverage; no app shelf."),
    15: ("exact", "13", "Curated Milk."),
    16: ("unsupported", "", "Beverage; no app shelf."),
    17: ("unsupported", "", "No app nut shelf; catalog has no hit either."),
    18: ("unsupported", "", "Red beans != app's Black Beans shelf; claiming Black Beans would be wrong."),
    19: ("unsupported", "", "No app nut shelf."),
    20: ("unsupported", "", "Dried fruit; no app shelf."),
    21: ("unsupported", "", "Soybeans; app's Soy Sauce is a processed product, not the same food."),
    22: ("unsupported", "", "No app nut shelf."),
    23: ("unsupported", "", "Peanuts != app's Peanut Butter shelf."),
    24: ("exact", "1", "Curated Egg."),
    25: ("exact", "40", "Curated Apple."),
    26: ("unsupported", "", "No app shelf."),
    27: ("unsupported", "", "No app shelf."),
    28: ("exact", "26", "Curated Avocado."),
    29: ("exact", "20", "Curated Banana."),
    30: ("unsupported", "", "No app shelf."),
    31: ("unsupported", "", "No app shelf."),
    32: ("unsupported", "", "No app shelf."),
    33: ("unsupported", "", "No app shelf."),
    34: ("exact", "169910", "USDA catalog 'Mango (Raw)' via the app's exact catalog path."),
    35: ("unsupported", "", "No app shelf."),
    36: ("unsupported", "", "No app shelf."),
    37: ("exact", "17", "Curated Lemon."),
    38: ("exact", "169118", "USDA catalog 'Pear (Raw)'."),
    39: ("unsupported", "", "No app shelf."),
    40: ("unsupported", "", "No app shelf."),
    41: ("unsupported", "", "No app shelf."),
    42: ("unsupported", "", "No app shelf."),
    43: ("unsupported", "", "No app shelf."),
    44: ("unsupported", "", "No app shelf (citrus beyond lemon absent)."),
    45: ("exact", "167765", "USDA catalog 'Watermelon (Raw)'."),
    46: ("coarse", "38", "App's only beef shelf is Ground Beef (38); prep mismatch noted (steak vs ground)."),
    47: ("ambiguous", "167813", "Catalog hit is 'Pork Fat (Raw)' - semantically unreliable for pork meat; kept visible as an app-behavior finding."),
    48: ("coarse", "4", "App shelf Chicken Breast (4); class also covers duck."),
    49: ("unsupported", "", "No catalog hit; app cannot express sausage."),
    50: ("ambiguous", "38;4", "Generic 'fried meat' could be beef (38) or chicken (4) shelves; unresolvable at class level."),
    51: ("unsupported", "", "No app shelf."),
    52: ("unsupported", "", "Generic sauce; app shelves are specific (Soy Sauce, oils)."),
    53: ("unsupported", "", "No app shelf."),
    54: ("coarse", "36", "App's only fresh-fish shelf is Salmon (36); class covers all fish."),
    55: ("unsupported", "", "No app shelf."),
    56: ("unsupported", "", "No catalog hit; app cannot express shrimp."),
    57: ("unsupported", "", "Dish; no app shelf."),
    58: ("exact", "15", "Curated Bread."),
    59: ("exact", "34", "Curated Corn."),
    60: ("unsupported", "", "Dish (hamburger)."),
    61: ("unsupported", "", "Dish (pizza)."),
    62: ("unsupported", "", "Dish (baozi). Official class name has a leading space, preserved in class_name_raw."),
    63: ("unsupported", "", "Dish (dumplings)."),
    64: ("exact", "9", "Curated Pasta."),
    65: ("coarse", "9", "App pasta shelf (9); noodles are not pasta but there is no closer shelf."),
    66: ("exact", "2", "Curated Rice."),
    67: ("unsupported", "", "Dish (pie)."),
    68: ("exact", "23", "Curated Tofu."),
    69: ("exact", "169228", "USDA catalog 'Eggplant (Raw)'."),
    70: ("exact", "10", "Curated Potato."),
    71: ("exact", "6", "Curated Garlic."),
    72: ("exact", "169986", "USDA catalog 'Cauliflower (Raw)'."),
    73: ("exact", "7", "Curated Tomato."),
    74: ("exact", "168457", "USDA catalog 'Kelp (Raw)'."),
    75: ("unsupported", "", "Kelp (74) exists in catalog but seaweed is a different food; left unsupported."),
    76: ("exact", "21", "Curated Green Onion via the app's 'spring onion' synonym."),
    77: ("unsupported", "", "Rapeseed greens/choy; no app shelf."),
    78: ("exact", "30", "Curated Ginger."),
    79: ("exact", "169260", "USDA catalog 'Okra (Raw)'."),
    80: ("exact", "39", "Curated Lettuce."),
    81: ("exact", "168448", "USDA catalog 'Pumpkin (Raw)'."),
    82: ("exact", "25", "Curated Cucumber."),
    83: ("unsupported", "", "Daikon; no app shelf."),
    84: ("exact", "11", "Curated Carrot."),
    85: ("exact", "168389", "USDA catalog 'Asparagus (Raw)'."),
    86: ("exact", "169210", "USDA catalog 'Bamboo Shoots (Raw)'."),
    87: ("exact", "24", "Curated Broccoli."),
    88: ("exact", "44", "Semantically app's Celery (44), but the app resolver returns nil for 'celery stick' - product gap."),
    89: ("ambiguous", "48", "One class covers cilantro AND mint; app has only Cilantro (48)."),
    90: ("exact", "170010", "USDA catalog 'Edible-Podded Peas (Raw)' - semantically right for snow peas."),
    91: ("exact", "169975", "USDA catalog 'Cabbage (Raw)'; official name has a leading space, resolver normalization handles it."),
    92: ("unsupported", "", "No app shelf."),
    93: ("exact", "5", "Curated Onion."),
    94: ("exact", "8", "FoodSeg 'pepper' is bell pepper; app resolver returns nil (no 'pepper' label/alias) - product gap; name collides with black pepper in English."),
    95: ("exact", "169961", "USDA catalog 'Green Beans (Raw)'. Note: the app's OCR-path masking of 'green beans' does NOT apply to classification labels, which resolve via catalog."),
    96: ("exact", "169961", "'French beans' = green beans (169961), but the app resolver returns nil - product gap."),
    97: ("coarse", "18", "App Mushroom shelf (18)."),
    98: ("exact", "169242", "USDA catalog 'Shiitake Mushrooms (Raw)'."),
    99: ("coarse", "18", "App Mushroom shelf (18)."),
    100: ("coarse", "18", "App Mushroom shelf (18)."),
    101: ("coarse", "18", "App Mushroom shelf (18)."),
    102: ("unsupported", "", "Dish/mix; not an ingredient claim."),
    103: ("unsupported", "", "Official catch-all; not an ingredient claim."),
}


def main() -> None:
    id2label = json.loads((HERE / "foodseg103_id2label.json").read_text())
    probe = json.loads(PROBE.read_text())
    lex = json.loads((RESOLUTION / "lexicon_snapshot.json").read_text())

    rows = []
    for cid in range(1, 104):
        raw_name = id2label[str(cid)]
        kind, targets, rationale = JUDGMENT[cid]
        probe_result = probe.get(raw_name)
        if probe_result is None:
            resolution_id, resolution_prov, resolution_display = "", "", ""
        else:
            resolution_id = str(probe_result["id"])
            resolution_prov = probe_result["prov"]
            resolution_display = probe_result["display"]
        target_list = [t for t in targets.split(";") if t]
        resolution_agrees = ""
        if target_list and resolution_id:
            resolution_agrees = "yes" if resolution_id in target_list else "no"
        rows.append(
            {
                "class_id": cid,
                "class_name_raw": raw_name,
                "class_name_normalized": raw_name.strip(),
                "semantic_kind": kind,
                "target_ingredient_ids": targets,
                "target_display_names": ";".join(
                    lex["displayNames"].get(t, f"catalog:{t}") for t in target_list
                ),
                "resolution_ingredient_id": resolution_id,
                "resolution_provenance": resolution_prov,
                "resolution_display_name": resolution_display,
                "resolution_agrees_with_semantic": resolution_agrees,
                "rationale": rationale,
            }
        )

    out = HERE / "foodseg103_to_catalog.csv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), quoting=csv.QUOTE_ALL)
        w.writeheader()
        w.writerows(rows)
    kinds = {}
    for r in rows:
        kinds[r["semantic_kind"]] = kinds.get(r["semantic_kind"], 0) + 1
    gaps = [r["class_name_normalized"] for r in rows if r["resolution_agrees_with_semantic"] == "" and r["target_ingredient_ids"]]
    disagrees = [r["class_name_normalized"] for r in rows if r["resolution_agrees_with_semantic"] == "no"]
    print(f"wrote {out}: {kinds}")
    print(f"semantic targets with NO resolution hit (product gaps): {gaps}")
    print(f"resolution disagrees with semantic target: {disagrees}")


if __name__ == "__main__":
    main()
