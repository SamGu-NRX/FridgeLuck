#!/usr/bin/env python3
"""Generate Swift static USDA ingredient nutrition dataset from compact JSON."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

DEFAULT_JSON = Path("FridgeLuck.swiftpm/Resources/usda_ingredient_nutrition_compact.json")
DEFAULT_SWIFT = Path("FridgeLuck.swiftpm/Data/Static/USDAIngredientNutritionStaticData.swift")


def swift_string(value: Any) -> str:
    if value is None:
        return "nil"
    s = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'


def swift_number(value: Any) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        text = f"{float(value):.4f}".rstrip("0").rstrip(".")
        return text or "0"
    return str(value)


def generate_swift(payload: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("import Foundation")
    lines.append("")
    lines.append("// Auto-generated from Resources/usda_ingredient_nutrition_compact.json")
    lines.append("// Source: USDA FoodData Central")
    lines.append("")
    lines.append("struct USDAIngredientNutritionRecord: Identifiable, Sendable {")
    lines.append("  let ingredientId: Int64")
    lines.append("  let ingredientKey: String")
    lines.append("  let ingredientName: String")
    lines.append("  let queryUsed: String")
    lines.append("  let matchedFdcId: Int64?")
    lines.append("  let matchedDescription: String?")
    lines.append("  let matchedDataType: String?")
    lines.append("  let matchedFoodCategory: String?")
    lines.append("  let matchScore: Double?")
    lines.append("  let calories: Double")
    lines.append("  let proteinG: Double")
    lines.append("  let carbsG: Double")
    lines.append("  let fatG: Double")
    lines.append("  let fiberG: Double")
    lines.append("  let sugarG: Double")
    lines.append("  let sodiumG: Double")
    lines.append("  let source: String")
    lines.append("  let error: String?")
    lines.append("")
    lines.append("  var id: Int64 { ingredientId }")
    lines.append("}")
    lines.append("")
    lines.append("enum USDAIngredientNutritionStaticData {")
    lines.append(f"  static let source = {swift_string(payload.get('source'))}")
    lines.append(f"  static let generatedAtUTC = {swift_string(payload.get('generated_at_utc'))}")
    lines.append(f"  static let ingredientCount = {swift_number(payload.get('ingredient_count'))}")
    lines.append(f"  static let matchedCount = {swift_number(payload.get('matched_count'))}")
    lines.append("")
    lines.append("  static let records: [USDAIngredientNutritionRecord] = [")

    for row in payload.get("records", []):
        lines.append("    USDAIngredientNutritionRecord(")
        lines.append(f"      ingredientId: {swift_number(row.get('ingredient_id'))},")
        lines.append(f"      ingredientKey: {swift_string(row.get('ingredient_key'))},")
        lines.append(f"      ingredientName: {swift_string(row.get('ingredient_name'))},")
        lines.append(f"      queryUsed: {swift_string(row.get('query_used'))},")
        lines.append(f"      matchedFdcId: {swift_number(row.get('matched_fdc_id'))},")
        lines.append(f"      matchedDescription: {swift_string(row.get('matched_description'))},")
        lines.append(f"      matchedDataType: {swift_string(row.get('matched_data_type'))},")
        lines.append(f"      matchedFoodCategory: {swift_string(row.get('matched_food_category'))},")
        lines.append(f"      matchScore: {swift_number(row.get('match_score'))},")
        lines.append(f"      calories: {swift_number(row.get('calories'))},")
        lines.append(f"      proteinG: {swift_number(row.get('protein_g'))},")
        lines.append(f"      carbsG: {swift_number(row.get('carbs_g'))},")
        lines.append(f"      fatG: {swift_number(row.get('fat_g'))},")
        lines.append(f"      fiberG: {swift_number(row.get('fiber_g'))},")
        lines.append(f"      sugarG: {swift_number(row.get('sugar_g'))},")
        lines.append(f"      sodiumG: {swift_number(row.get('sodium_g'))},")
        lines.append(f"      source: {swift_string(row.get('source'))},")
        lines.append(f"      error: {swift_string(row.get('error'))}")
        lines.append("    ),")

    lines.append("  ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in-json", type=Path, default=DEFAULT_JSON)
    parser.add_argument("--out-swift", type=Path, default=DEFAULT_SWIFT)
    args = parser.parse_args()

    payload = json.loads(args.in_json.read_text(encoding="utf-8"))
    swift_text = generate_swift(payload)

    args.out_swift.parent.mkdir(parents=True, exist_ok=True)
    args.out_swift.write_text(swift_text, encoding="utf-8")
    print(f"Wrote Swift static dataset to {args.out_swift}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
