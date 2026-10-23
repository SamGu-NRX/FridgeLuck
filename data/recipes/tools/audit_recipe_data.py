"""Deterministic offline audit for the shipped recipe bundle.

This tool reports data that needs a human decision. It never changes recipe
visibility and never guesses an amount or allergen classification.
"""
from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path
from typing import Any

BUNDLE = Path(__file__).parents[3] / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"
REPORT = Path(__file__).parents[2] / "recipe-bundle/recipe-data-audit.md"

VOLUME_UNITS = {"cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons", "ml", "l", "liter", "liters", "fl oz"}
LIQUID_WORDS = {"water", "milk", "broth", "stock", "oil", "vinegar", "juice", "sauce", "cream", "yogurt", "syrup", "wine", "coffee", "tea"}
LIQUID_DENSITY_RANGES = {
    "cup": (150, 500), "cups": (150, 500), "tbsp": (8, 30),
    "tablespoon": (8, 30), "tablespoons": (8, 30), "tsp": (2, 12),
    "teaspoon": (2, 12), "teaspoons": (2, 12), "ml": (0.5, 1.5),
    "l": (500, 1500), "liter": (500, 1500), "liters": (500, 1500),
    "fl oz": (5, 40),
}

# No correction is made without a recipe citation or USDA/FDC evidence.
# Keep this explicit so the citation test covers future corrections.
CORRECTIONS: list[dict[str, str]] = []


def _number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _liquidish(key: str) -> bool:
    words = set(key.replace("_", " ").split())
    return bool(words & LIQUID_WORDS)


def audit_bundle(bundle: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    ingredients = {row["key"]: row for row in bundle["ingredients"]}
    findings: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for recipe in bundle["recipes"]:
        rid = recipe["catalog_id"]
        servings = recipe["servings"]
        seen: set[str] = set()
        for index, line in enumerate(recipe["ingredients"]):
            key = line["key"]
            quantity = line["quantity"]
            location = {"recipe": rid, "title": recipe["title"], "line": index, "ingredient": key}
            if key in seen:
                findings["duplicate_ingredients"].append({**location, "reason": "ingredient key appears more than once"})
            seen.add(key)

            kind = quantity["kind"]
            if kind in {"household", "count"}:
                unit = str(quantity.get("unit", "")).strip()
                if not unit:
                    findings["missing_units"].append({**location, "reason": "household/count quantity has no unit"})
                amount = quantity.get("amount")
                if not _number(amount) or not math.isfinite(amount) or amount <= 0:
                    findings["amounts"].append({**location, "reason": f"invalid amount {amount!r}"})
                grams = quantity.get("grams")
                if grams is not None and (not _number(grams) or not math.isfinite(grams) or grams <= 0 or grams > 5000):
                    findings["amounts"].append({**location, "reason": f"invalid converted grams {grams!r}"})
                if _number(amount) and _number(grams) and amount > 0 and grams > 0:
                    per_serving = amount * grams / servings
                    if per_serving > 2000:
                        findings["amounts"].append({**location, "reason": f"{per_serving:g} converted grams per serving is implausibly high"})
                    normalized_unit = unit.lower()
                    if normalized_unit in VOLUME_UNITS:
                        density = grams / amount
                        if _liquidish(key):
                            lower, upper = LIQUID_DENSITY_RANGES.get(normalized_unit, (0.5, 1500))
                        else:
                            # Do not reject normal culinary volume conversions for
                            # dense spices or leafy herbs. Only extreme values are
                            # evidence of a likely unit mismatch.
                            lower, upper = (1, 2000)
                        if density < lower or density > upper:
                            findings["unit_mismatches"].append({**location, "reason": f"{amount:g} {unit} converts to {grams:g} g ({density:g} g/{unit}), outside the plausible range for this ingredient"})
            elif kind == "grams":
                grams = quantity.get("grams")
                if not _number(grams) or not math.isfinite(grams) or grams <= 0 or grams > 5000:
                    findings["amounts"].append({**location, "reason": f"invalid grams {grams!r}"})
                elif grams / servings > 2000:
                    findings["amounts"].append({**location, "reason": f"{grams / servings:g} converted grams per serving is implausibly high"})
            elif kind == "unknown":
                pass
            else:
                findings["amounts"].append({**location, "reason": f"unsupported quantity kind {kind!r}"})

    uses: dict[str, list[dict[str, str]]] = defaultdict(list)
    for recipe in bundle["recipes"]:
        for line in recipe["ingredients"]:
            uses[line["key"]].append({"catalog_id": recipe["catalog_id"], "title": recipe["title"]})
    for row in bundle["ingredients"]:
        if "unknown" in row.get("classes", []):
            findings["unknown_allergens"].append({
                "ingredient": row["key"],
                "display_name": row["display_name"],
                "classes": row["classes"],
                "recipes": uses[row["key"]],
            })
    return {key: findings[key] for key in sorted(findings)}


def validate_corrections(corrections: list[dict[str, str]]) -> None:
    for correction in corrections:
        citation = correction.get("citation", "").strip()
        if not citation:
            raise ValueError(f"correction lacks a citation: {correction}")


def load_bundle(path: Path = BUNDLE) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def render_report(bundle: dict[str, Any], findings: dict[str, list[dict[str, Any]]]) -> str:
    validate_corrections(CORRECTIONS)
    lines = [
        "# Recipe data audit",
        "",
        "- Source: `apps/ios/Resources/RecipeCatalog/recipes-v2.json`",
        "- Schema: `docs/spec/recipes/contracts/recipe-bundle-v2.schema.json`",
        f"- Recipes audited: {len(bundle['recipes'])}",
        f"- Ingredients audited: {len(bundle['ingredients'])}",
        "- Corrections made: none. No amount or allergen state was changed without a cited source.",
        "- Visibility recommendations: none. This audit does not decide which recipes are shown.",
        "",
        "## Amount and unit findings",
        "",
    ]
    for category in ("amounts", "missing_units", "unit_mismatches", "duplicate_ingredients"):
        rows = findings.get(category, [])
        lines.append(f"### {category.replace('_', ' ').title()} ({len(rows)})")
        if not rows:
            lines.append("None.")
        else:
            for row in rows:
                lines.append(f"- `{row['recipe']}` — {row['title']}; `{row['ingredient']}`: {row['reason']}")
        lines.append("")
    unknown = findings.get("unknown_allergens", [])
    lines += [f"## Unknown allergen state ({len(unknown)} ingredients)", "", "Unknown is represented by the `unknown` class in the ingredient vocabulary. No unknown state was resolved by guessing.", ""]
    for row in unknown:
        recipes = ", ".join(f"`{r['catalog_id']}` ({r['title']})" for r in row["recipes"])
        lines.append(f"- `{row['ingredient']}` ({row['display_name']}; classes: `{', '.join(row['classes'])}`): {recipes}")
    lines += ["", "## Corrections", "", "None. Any future correction must include a recipe-source or USDA FoodData Central citation next to the changed value.", ""]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", nargs="?", type=Path, default=BUNDLE)
    parser.add_argument("--report", type=Path, default=REPORT)
    args = parser.parse_args()
    bundle = load_bundle(args.bundle)
    findings = audit_bundle(bundle)
    args.report.write_text(render_report(bundle, findings), encoding="utf-8")
    total = sum(len(rows) for rows in findings.values())
    print(f"audited {len(bundle['recipes'])} recipes and {len(bundle['ingredients'])} ingredients; {total} findings")
    for category, rows in findings.items():
        print(f"{category}: {len(rows)}")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
