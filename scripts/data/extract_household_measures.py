#!/usr/bin/env python3
"""Extract USDA FNDDS (FoodData Central Survey Foods) household-measure
portions into pinned, reviewable reference tables.

Inputs (fetched once, cached in scripts/data/.cache):
  FNDDS Survey Foods JSON, edition 2024-10-31.
  https://fdc.nal.usda.gov/fdc-datasets/foodData_513.surveyDownload.json.zip?cachebust=2024103101

Outputs (committed under scripts/data/reference/household_measures/):
  fndds_portions.csv          every survey-food portion with a positive
                              gramWeight (raw source rows, provenance-ready)
  fndds_household_units.csv   only the portions that parse to a canonical
                              household unit, with grams_per_unit
  mass_conversion_table.json  compact resource consumed by the Swift
                              MassConversionKit contract tests
  MANIFEST.json               provenance: source URL, archive SHA-256,
                              edition, row counts, unit inventory

The script is deterministic: identical inputs produce byte-identical outputs
apart from the generated_at timestamp recorded in MANIFEST.json.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from usda_core.households import (  # noqa: E402
    classify_packing,
    classify_preparation_state,
    parse_portion_description,
)

SOURCE_URL = (
    "https://fdc.nal.usda.gov/fdc-datasets/foodData_513.surveyDownload.json.zip"
    "?cachebust=2024103101"
)
SOURCE_EDITION = "2024-10-31"
# SHA-256 of the downloaded .zip archive as fetched from fdc.nal.usda.gov.
ARCHIVE_SHA256 = (
    "dfb06ae7ddc397ccd570b91c14b75438ab2ba39f64f22d321f61d4a52a77f3eb"
)
# SHA-256 of the unpacked surveyDownload.json this extraction consumes.
EXPECTED_SHA256 = (
    "2e7eb9fda92adf1d4d784dba5eaa3a7fd4418cd86ccff383c7c9294d79e9b808"
)

DATA_DIR = Path(__file__).resolve().parent
CACHE_JSON = DATA_DIR / ".cache" / "surveyDownload.json"
OUT_DIR = DATA_DIR / "reference" / "household_measures"

CSV_QUOTING = csv.QUOTE_ALL
CSV_LINETERMINATOR = "\r\n"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    args = parser.parse_args()

    if not CACHE_JSON.exists():
        print(
            f"missing cached survey JSON: {CACHE_JSON}\n"
            f"download and unpack {SOURCE_URL} (archive SHA-256 {ARCHIVE_SHA256})",
            file=sys.stderr,
        )
        return 2

    actual_sha = sha256_file(CACHE_JSON)
    if actual_sha != EXPECTED_SHA256:
        print(
            "cached survey JSON SHA-256 mismatch:\n"
            f"  expected {EXPECTED_SHA256}\n  actual   {actual_sha}",
            file=sys.stderr,
        )
        return 2

    document = json.loads(CACHE_JSON.read_text(encoding="utf-8"))
    foods = document["SurveyFoods"]

    raw_rows: list[dict] = []
    parsed_rows: list[dict] = []
    unit_counts: Counter[str] = Counter()
    foods_with_positive_portions = 0

    for food in foods:
        portions = food.get("foodPortions") or []
        food_positive = False
        for portion in portions:
            gram_weight = portion.get("gramWeight") or 0
            if gram_weight <= 0:
                continue
            food_positive = True
            description = food.get("description") or ""
            category = (food.get("wweiaFoodCategory") or {}).get(
                "wweiaFoodCategoryDescription", ""
            )
            portion_description = portion.get("portionDescription") or ""
            modifier = portion.get("modifier") or ""
            raw_rows.append(
                {
                    "fdc_id": food.get("fdcId"),
                    "food_description": description,
                    "category": category,
                    "portion_description": portion_description,
                    "modifier": modifier,
                    "gram_weight": gram_weight,
                }
            )
            parsed = parse_portion_description(portion_description)
            if parsed is None:
                continue
            unit_counts[parsed.unit] += 1
            parsed_rows.append(
                {
                    "fdc_id": food.get("fdcId"),
                    "food_description": description,
                    "category": category,
                    "portion_description": portion_description,
                    "modifier": modifier,
                    "unit": parsed.unit,
                    "magnitude": f"{parsed.magnitude:g}",
                    "gram_weight": gram_weight,
                    "grams_per_unit": f"{gram_weight / parsed.magnitude:.4f}",
                }
            )
        if food_positive:
            foods_with_positive_portions += 1

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    def write_csv(path: Path, rows: list[dict]) -> None:
        if not rows:
            raise SystemExit(f"refusing to write empty table {path}")
        with path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=list(rows[0].keys()),
                quoting=CSV_QUOTING,
                lineterminator=CSV_LINETERMINATOR,
            )
            writer.writeheader()
            writer.writerows(rows)

    portions_csv = OUT_DIR / "fndds_portions.csv"
    units_csv = OUT_DIR / "fndds_household_units.csv"
    write_csv(portions_csv, raw_rows)
    write_csv(units_csv, parsed_rows)

    # Compact Swift resource: one entry per (food, unit, magnitude) with the
    # implied grams for that quantity. Duplicate (food, unit, magnitude) rows
    # keep their first occurrence so the table is deterministic.
    conversion: dict[tuple[int, str, float], dict] = {}
    for row in parsed_rows:
        key = (row["fdc_id"], row["unit"], float(row["magnitude"]))
        if key in conversion:
            continue
        state_context = f"{row['portion_description']} {row['modifier']}"
        conversion[key] = {
            "fdcId": row["fdc_id"],
            "food": row["food_description"],
            "unit": row["unit"],
            "magnitude": float(row["magnitude"]),
            "grams": float(row["gram_weight"]),
            "state": classify_preparation_state(state_context),
            "packing": classify_packing(state_context),
        }
    swift_table = {
        "source": {
            "dataset": "USDA FoodData Central Survey Foods (FNDDS)",
            "edition": SOURCE_EDITION,
            "url": SOURCE_URL,
            "archiveSha256": ARCHIVE_SHA256,
            "surveyJsonSha256": EXPECTED_SHA256,
        },
        "portions": [conversion[key] for key in sorted(conversion)],
    }
    table_json = OUT_DIR / "mass_conversion_table.json"
    table_json.write_text(
        json.dumps(swift_table, separators=(",", ":")) + "\n", encoding="utf-8"
    )

    manifest = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "dataset": "USDA FoodData Central Survey Foods (FNDDS)",
            "edition": SOURCE_EDITION,
            "url": SOURCE_URL,
            "archive_sha256": ARCHIVE_SHA256,
            "survey_json_sha256": EXPECTED_SHA256,
            "survey_foods": len(foods),
        },
        "outputs": {
            "fndds_portions.csv": {
                "rows": len(raw_rows),
                "description": "all FNDDS portions with positive gramWeight",
            },
            "fndds_household_units.csv": {
                "rows": len(parsed_rows),
                "description": (
                    "portions that parse to a canonical household unit, with "
                    "grams_per_unit"
                ),
            },
            "mass_conversion_table.json": {
                "rows": len(conversion),
                "description": (
                    "deduplicated (food, unit, magnitude) conversions for the "
                    "Swift MassConversionKit contract tests"
                ),
            },
        },
        "unit_inventory": dict(
            sorted(unit_counts.items(), key=lambda item: (-item[1], item[0]))
        ),
        "coverage": {
            "survey_foods": len(foods),
            "foods_with_positive_portions": foods_with_positive_portions,
            "positive_portion_rows": len(raw_rows),
            "parsed_household_rows": len(parsed_rows),
        },
    }
    manifest_path = OUT_DIR / "MANIFEST.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )

    print(
        f"wrote {len(raw_rows)} raw portions, {len(parsed_rows)} household rows, "
        f"{len(conversion)} conversions to {OUT_DIR}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
