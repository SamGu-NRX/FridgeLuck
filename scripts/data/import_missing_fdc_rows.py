#!/usr/bin/env python3
"""Add USDA FoodData Central rows the recipe catalog needs but the app catalog lacks.

The bundle-v2 vocabulary carries an `fdc_id` on most ingredient keys. When that id is
missing from the shipped `usda_ingredient_catalog.sqlite`, the hydration-time identity
bridge cannot resolve the key, and every recipe line on it counts as "not in your
kitchen". This tool closes that gap from cited data only:

  1. Read the shipped bundle vocabulary and the canonical catalog
     (`catalog/usda_curated_ingredients.json`); list the `fdc_id`s the vocabulary
     references that the canonical catalog does not carry.
  2. For each missing id, take the exact food row from the public FDC bulk CSV
     downloads (Foundation / SR Legacy / Survey (FNDDS), CC0, no API key): the
     description becomes the display name, and the per-100 g macros come from the
     row's food_nutrient entries (Energy, Protein, Carbohydrate, Total lipid, Fiber,
     Total sugars, Sodium).
  3. Merge the new records into the canonical catalog (sorted by fdc_id, the schema's
     own validation applies), leaving every existing row byte-identical (macro freeze).

A vocabulary key with no `fdc_id` resolves only through a legacy id or a cited
same-food FDC row of its own; this tool never invents one. Keys it cannot cover are
left unresolved and are listed in the reach report.

Usage:
  python3 scripts/data/import_missing_fdc_rows.py \
      --fdc-csv-root /tmp/fdc/ext \
      --repo-root /path/to/FridgeLuck
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

# Per-100 g nutrient ids in FDC bulk downloads. Survey (FNDDS) rows use the
# legacy nutrient_nbr ids (208/203/...) in food_nutrient.csv; Foundation and
# SR Legacy use the FDC master ids (1008/1003/...). Prefer the FDC id, fall
# back to the legacy one.
NUTRIENT_ENERGY_KCAL = [1008, 208, 2047]  # 2047 = Energy (Atwater General, kcal), reported by Foundation rows that omit 1008
NUTRIENT_PROTEIN = [1003, 203]
NUTRIENT_CARBES = [1005, 205]
NUTRIENT_FAT = [1004, 204]
NUTRIENT_FIBER = [1079, 291]
NUTRIENT_SODIUM = [1093, 307]
NUTRIENT_SUGARS = [2000, 1063, 269]  # prefer "Total Sugars" style ids, first hit wins

SMALL_WORDS = {"and", "or", "of", "in", "with", "without", "to", "for", "on", "a", "an", "the"}
UPPER_TOKENS = {"nfs", "ns", "na", "wt", "iqf", "usda", "php", "bpa"}


def title_case(description: str) -> str:
    """Humanize an FDC description. Uppercase descriptions become title case with
    small words lowercase; mixed-case descriptions pass through unchanged."""
    text = " ".join(description.split())
    if not text or not text.isupper():
        return text

    def fix_word(word: str) -> str:
        lowered = word.lower()
        if lowered in UPPER_TOKENS:
            return lowered.upper()
        if lowered in SMALL_WORDS:
            return lowered
        return lowered[:1].upper() + lowered[1:]

    words = [fix_word(w) for w in text.lower().split(" ")]
    # The first word always capitalizes.
    if words:
        words[0] = words[0][:1].upper() + words[0][1:]
    return " ".join(words)


def load_vocabulary(bundle_path: Path) -> list[dict]:
    bundle = json.loads(bundle_path.read_text())
    return bundle["ingredients"]


def load_canonical(canonical_path: Path) -> dict:
    return json.loads(canonical_path.read_text())


def missing_fdc_ids(vocabulary: list[dict], canonical: dict) -> dict[int, list[str]]:
    """fdc_id -> vocabulary keys that reference it, for ids the canonical lacks."""
    have = {row["fdc_id"] for row in canonical["records"]}
    wanted: dict[int, list[str]] = defaultdict(list)
    for row in vocabulary:
        fdc_id = row.get("fdc_id")
        if fdc_id is not None and int(fdc_id) not in have:
            wanted[int(fdc_id)].append(row["key"])
    return dict(wanted)


def read_food_rows(csv_root: Path) -> dict[int, dict]:
    """fdc_id -> {description, data_type, category} across the three public datasets."""
    datasets = [
        ("FoodData_Central_foundation_food_csv", "Foundation"),
        ("FoodData_Central_sr_legacy_food_csv", "SR Legacy"),
        ("FoodData_Central_survey_food_csv", "Survey (FNDDS)"),
    ]
    foods: dict[int, dict] = {}
    for prefix, data_type in datasets:
        dataset_dir = next(csv_root.glob(f"{prefix}_*/{prefix}_*"), None)
        if dataset_dir is None:
            continue
        category_names = read_category_names(dataset_dir)
        with (dataset_dir / "food.csv").open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                fdc_id = int(row["fdc_id"])
                category = category_names.get(
                    row.get("food_category_id", ""), f"{data_type} foods"
                )
                foods[fdc_id] = {
                    "description": row["description"],
                    "data_type": data_type,
                    "food_category": category,
                }
    return foods


def read_category_names(dataset_dir: Path) -> dict[str, str]:
    names: dict[str, str] = {}
    category_csv = dataset_dir / "food_category.csv"
    if category_csv.exists():
        with category_csv.open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                names[row["id"]] = row.get("description", "")
    wweia_csv = dataset_dir / "wweia_food_category.csv"
    if wweia_csv.exists():
        with wweia_csv.open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                code = row.get("wweia_food_category", row.get("code", ""))
                names[code] = row.get("wweia_food_category_description", row.get("description", ""))
    return names


def read_macros(csv_root: Path, fdc_ids: set[int]) -> dict[int, dict[str, float]]:
    """fdc_id -> per-100 g macros from food_nutrient.csv across the datasets."""
    amounts: dict[int, dict[int, float]] = defaultdict(dict)
    for prefix in [
        "FoodData_Central_foundation_food_csv",
        "FoodData_Central_sr_legacy_food_csv",
        "FoodData_Central_survey_food_csv",
    ]:
        dataset_dir = next(csv_root.glob(f"{prefix}_*/{prefix}_*"), None)
        if dataset_dir is None:
            continue
        nutrient_csv = dataset_dir / "food_nutrient.csv"
        if not nutrient_csv.exists():
            continue
        with nutrient_csv.open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                fdc_id = int(row["fdc_id"])
                if fdc_id not in fdc_ids:
                    continue
                nutrient_id = int(row["nutrient_id"])
                amounts[fdc_id][nutrient_id] = float(row["amount"])

    macros_by_id: dict[int, dict[str, float]] = {}

    def first_amount(per_nutrient: dict[int, float], ids: list[int]) -> float:
        for nutrient_id in ids:
            if nutrient_id in per_nutrient:
                return per_nutrient[nutrient_id]
        return 0.0

    for fdc_id, per_nutrient in amounts.items():
        macros_by_id[fdc_id] = {
            "calories": round(first_amount(per_nutrient, NUTRIENT_ENERGY_KCAL), 4),
            "protein_g": round(first_amount(per_nutrient, NUTRIENT_PROTEIN), 4),
            "carbs_g": round(first_amount(per_nutrient, NUTRIENT_CARBES), 4),
            "fat_g": round(first_amount(per_nutrient, NUTRIENT_FAT), 4),
            "fiber_g": round(first_amount(per_nutrient, NUTRIENT_FIBER), 4),
            "sugar_g": round(first_amount(per_nutrient, NUTRIENT_SUGARS), 4),
            "sodium_g": round(first_amount(per_nutrient, NUTRIENT_SODIUM) / 1000.0, 4),
        }
    return macros_by_id


VOCAB_CATEGORY_TO_LABEL = {
    "meat": "protein",
    "fish": "protein",
    "shellfish": "protein",
    "spice": "herb_spice",
    "grain": "grain_legume",
    "dairy_egg": "dairy_egg",
    "vegetable": "vegetable",
    "fruit": "fruit",
    "condiment": "condiment",
    "other": "other",
}

FDC_CATEGORY_TO_LABEL = {
    "Dairy and Egg Products": "dairy_egg",
    "Fats and Oils": "oil_fat",
    "Poultry Products": "protein",
    "Sausages and Luncheon Meats": "protein",
    "Pork Products": "protein",
    "Beef Products": "protein",
    "Finfish and Shellfish Products": "protein",
    "Lamb, Veal, and Game Products": "protein",
    "Vegetables and Vegetable Products": "vegetable",
    "Fruits and Fruit Juices": "fruit",
    "Legumes and Legume Products": "grain_legume",
    "Nut and Seed Products": "nut_seed",
    "Spices and Herbs": "herb_spice",
    "Soups, Sauces, and Gravies": "condiment",
    "Grains and Pasta": "grain_legume",
    "Breakfast Cereals": "grain_legume",
    "Baked Products": "sweetener_baking",
    "Sweets": "sweetener_baking",
    "Sweeteners": "sweetener_baking",
}


def choose_category(
    vocab_categories: list[str], fdc_category: str | None
) -> str:
    for category in vocab_categories:
        label = VOCAB_CATEGORY_TO_LABEL.get(category)
        if label:
            return label
    if fdc_category and fdc_category in FDC_CATEGORY_TO_LABEL:
        return FDC_CATEGORY_TO_LABEL[fdc_category]
    return "other"


def unique_display_name(
    display_name: str, fdc_id: int, taken: set[str], data_type: str
) -> str:
    """Keep canonical display names unique; `taken` holds canonical keys and is updated."""
    from usda_core.utils import canonical  # noqa: PLC0415 — local import keeps the CLI lean

    key = canonical(display_name)
    if key not in taken:
        taken.add(key)
        return display_name
    suffixed = f"{display_name} ({data_type})"
    suffixed_key = canonical(suffixed)
    if suffixed_key not in taken:
        taken.add(suffixed_key)
        return suffixed
    fallback = f"{display_name} (fdc {fdc_id})"
    taken.add(canonical(fallback))
    return fallback


def canonical_display_key(value: str) -> str:
    from usda_core.utils import canonical  # noqa: PLC0415

    return canonical(value)


def build_new_records(
    wanted: dict[int, list[str]],
    vocab_categories: dict[str, str],
    foods: dict[int, dict],
    macros_by_id: dict[int, dict[str, float]],
    taken_names: set[str],
) -> tuple[list[dict], list[dict]]:
    verified = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    new_records: list[dict] = []
    not_found: list[dict] = []
    for fdc_id in sorted(wanted):
        keys = wanted[fdc_id]
        categories = [vocab_categories.get(key, "other") for key in keys]
        food = foods.get(fdc_id)
        macros = macros_by_id.get(fdc_id)
        if food is None or macros is None:
            not_found.append({"fdc_id": fdc_id, "keys": keys})
            continue
        display_name = unique_display_name(
            title_case(food["description"]), fdc_id, taken_names, food["data_type"]
        )
        taken_names.add(display_name)
        category = choose_category(categories, food["food_category"])
        new_records.append(
            {
                "fdc_id": fdc_id,
                "display_name": display_name,
                "alt_names": [],
                "category_label": category,
                "sprite_group": "other",
                "sprite_key": "",
                "description": (
                    f"{display_name} is a USDA-listed ingredient; nutrition is per 100 g "
                    f"as reported by FoodData Central ({food['data_type']})."
                ),
                "source_description": food["description"],
                "source_meta": {
                    "data_type": food["data_type"],
                    "food_category": food["food_category"],
                    "verified_at_utc": verified,
                    "verification_source": "USDA FoodData Central bulk download (CC0)",
                },
                "macros": macros,
            }
        )
    return new_records, not_found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--fdc-csv-root", type=Path, required=True,
        help="Directory holding the extracted FDC bulk CSV downloads",
    )
    parser.add_argument(
        "--apply", action="store_true",
        help="Write the merged canonical JSON; without this flag the run is a dry report",
    )
    args = parser.parse_args()

    sys.path.insert(0, str(args.repo_root / "scripts" / "data"))

    bundle_path = args.repo_root / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"
    canonical_path = args.repo_root / "scripts/data/catalog/usda_curated_ingredients.json"

    vocabulary = load_vocabulary(bundle_path)
    canonical = load_canonical(canonical_path)
    vocab_categories = {row["key"]: row.get("category", "other") for row in vocabulary}

    wanted = missing_fdc_ids(vocabulary, canonical)
    print(f"missing fdc ids referenced by the vocabulary: {len(wanted)}")

    foods = read_food_rows(args.fdc_csv_root)
    print(f"food rows loaded from bulk downloads: {len(foods)}")

    macros_by_id = read_macros(args.fdc_csv_root, set(wanted))
    print(f"missing ids with nutrition rows: {len(macros_by_id)}")

    existing_names = {
        canonical_display_key(row["display_name"]) for row in canonical["records"]
    }
    new_records, not_found = build_new_records(
        wanted, vocab_categories, foods, macros_by_id, existing_names
    )
    print(f"new canonical records: {new_records and len(new_records)}")
    for entry in not_found:
        print(
            f"  NOT FOUND in bulk downloads: fdc_id={entry['fdc_id']} keys={entry['keys']}"
        )

    if not args.apply:
        print("dry run; pass --apply to merge into the canonical JSON")
        return 0

    from usda_core.io import load_canonical as load_canonical_catalog  # noqa: PLC0415
    from usda_core.io import save_canonical as save_canonical_catalog  # noqa: PLC0415
    from usda_core.schema import CuratedIngredientRow  # noqa: PLC0415
    from usda_core.validate import validate_catalog  # noqa: PLC0415

    merged = load_canonical_catalog(canonical_path)
    for record in new_records:
        merged.records.append(CuratedIngredientRow.model_validate(record))
    merged.records.sort(key=lambda row: row.fdc_id)
    validate_catalog(merged)
    save_canonical_catalog(canonical_path, merged)
    print(f"canonical catalog now carries {len(merged.records)} records")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
