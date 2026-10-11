#!/usr/bin/env python3
"""Evaluate the existing InventoryIntakeService gram estimator against USDA
FNDDS household-measure evidence — read-only, no estimator changes.

What this does:
  1. Slices the estimator's keyword tables and pure-string functions
     verbatim out of apps/ios/Platform/Persistence/Services/InventoryIntakeService.swift
     and wraps them in a generated `EstimatorReplay` Swift target. The only
     mechanical transforms: `private static` -> `public static`
     (accessibility widening) and `Ingredient?`
     -> the minimal `ReplayIngredient?` stand-in so the slice compiles off
     iOS. If the source file drifts, regenerate to pick up the drift — the
     replay can never silently diverge from the estimator.
  2. Builds a deterministic, source-bound example set (>= 100 FNDDS survey
     portions, each bound to an FDC id, description, portion description,
     unit, and USDA gram weight) from the pinned household-units table.
  3. Runs the replay via `swift run estimator-eval` and scores three arms:
       nameArm          estimateGrams(forName:) on the FNDDS description
       unitArm          estimateGrams(for:) with the canonical unit word
       unitPrefixedArm  estimateGrams(for:) with "1 <unit>"
  4. Runs the Swift `conversion-checks` executable (food-group-held-out
     recovery by leaving entire WWEIA categories out, plus the 100-meal
     conversion-path plumbing check).
  5. Derives a source-bound cooking-yield sensitivity arm: raw/cooked
     survey-food pairs (same normalized description stem, same WWEIA
     category) sharing a household unit with differing per-unit grams,
     with per-unit energy/macronutrient consequences computed from
     SurveyFoods per-100g nutrients on both sides.
  6. Scans the full FNDDS corpus portion text for packing terms and
     states plainly that FNDDS attaches no packing evidence to household
     portions — packing matching is exercised only by synthetic unit
     tests, so packing generalization is unmeasured.
  7. Writes estimator_examples.json, estimator_evaluation.csv,
     estimator_evaluation.md, conversion_checks.{json,md},
     yield_sensitivity.{json,md}, and packing_scan.{json,md} under
     reference/household_measures/.

The estimator file itself is never modified.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "scripts" / "data"
OUT_DIR = DATA_DIR / "reference" / "household_measures"
CACHE_JSON = DATA_DIR / ".cache" / "surveyDownload.json"

sys.path.insert(0, str(DATA_DIR))
from usda_core.households import (  # noqa: E402
    PACKING_SCAN_TERMS,
    derive_yield_pairs,
    scan_packing_terms,
)

CONVERSION_JSON = OUT_DIR / "conversion_checks.json"
CONVERSION_MD = OUT_DIR / "conversion_checks.md"
YIELD_JSON = OUT_DIR / "yield_sensitivity.json"
YIELD_MD = OUT_DIR / "yield_sensitivity.md"
PACKING_JSON = OUT_DIR / "packing_scan.json"
PACKING_MD = OUT_DIR / "packing_scan.md"
CONVERSION_TABLE_JSON = OUT_DIR / "mass_conversion_table.json"

# Per-100g nutrient anchors consumed by the yield-sensitivity arm
# (FNDDS foodNutrients entries are nested as nutrient.number).
YIELD_NUTRIENT_NUMBERS = {"208": "kcal", "203": "proteinG", "204": "fatG", "205": "carbG"}

EXTRACTOR = DATA_DIR / "extract_household_measures.py"
UNITS_CSV = OUT_DIR / "fndds_household_units.csv"
EXAMPLES_JSON = OUT_DIR / "estimator_examples.json"
EVAL_CSV = (
    DATA_DIR / "reference" / "household_measures" / "estimator_evaluation.csv"
)
EVAL_MD = (
    DATA_DIR / "reference" / "household_measures" / "estimator_evaluation.md"
)
ESTIMATOR_SWIFT = (
    REPO_ROOT
    / "apps/ios/Platform/Persistence/Services/InventoryIntakeService.swift"
)
PACKAGE_DIR = REPO_ROOT / "apps/ios/Tools/mass-conversion-check"
REPLAY_SWIFT = PACKAGE_DIR / "Sources" / "EstimatorReplay" / "EstimatorReplay.swift"

# Swift driver: explicit SWIFT_BIN env var wins, then PATH lookup, then a
# plain "swift" for whatever toolchain the environment provides. Nothing here
# hardcodes a machine-specific install path.
swift = os.environ.get("SWIFT_BIN") or shutil.which("swift") or "swift"

# Units sampled into the evaluation set, with a cap per family so rare units
# are represented without letting one family dominate.
SAMPLE_UNITS = [
    "cup", "tbsp", "tsp", "floz", "oz", "slice", "piece", "egg", "stick",
    "pat", "medium", "large", "small", "can", "package",
]
PER_UNIT_CAP = 12

# Ordered keyword buckets from estimatedGrams(forName:) — used ONLY to label
# which bucket produced each name-arm estimate. The estimate itself always
# comes from the replayed Swift code.
NAME_BUCKETS = [
    ("egg", ["egg"]),
    ("liquid", ["milk", "yogurt"]),
    ("oil/condiment", ["oil", "sauce", "honey", "mustard", "peanut butter", "sesame"]),
    ("leafy", ["spinach", "lettuce", "cilantro", "herb", "green onion"]),
    ("aromatic", ["garlic", "ginger", "chive"]),
    ("protein", ["chicken", "beef", "salmon", "tofu", "tuna"]),
    ("dry goods", ["rice", "pasta", "bean", "chickpea", "oat", "corn", "pea"]),
    ("bread", ["bread", "tortilla"]),
    ("produce", [
        "onion", "tomato", "pepper", "potato", "carrot", "mushroom", "broccoli",
        "cucumber", "avocado", "apple", "banana", "lemon", "lime", "zucchini",
        "celery",
    ]),
]


def source_commit() -> str:
    """Content hash (git blob SHA) of the estimator source at HEAD — NOT the
    current HEAD commit. Stamping current HEAD into the replay and reports
    would make every regeneration churn committed files on unrelated commits;
    the blob hash only changes when the estimator source itself does."""
    return subprocess.run(
        [
            "git",
            "rev-parse",
            f"HEAD:{ESTIMATOR_SWIFT.relative_to(REPO_ROOT)}",
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def slice_block(source: str, needle: str) -> str:
    """Return the brace/bracket-matched block starting at the line that
    contains `needle`."""
    lines = source.splitlines()
    start = next(i for i, line in enumerate(lines) if needle in line)
    depth = 0
    opened = False
    for index in range(start, len(lines)):
        for char in lines[index]:
            if char in "{[":
                depth += 1
                opened = True
            elif char in "}]" and opened:
                depth -= 1
        if opened and depth == 0:
            return "\n".join(lines[start : index + 1])
    raise SystemExit(f"unbalanced block for {needle!r}")


def build_replay(source: str, commit: str) -> str:
    blocks = []
    for needle in [
        "private static let pantryLocationKeywords",
        "private static let fridgeLocationKeywords",
        "private static let liquidMassKeywords",
        "private static let oilAndCondimentKeywords",
        "private static let leafyProduceKeywords",
        "private static let aromaticKeywords",
        "private static let proteinKeywords",
        "private static let dryGoodsKeywords",
        "private static let breadKeywords",
        "private static let produceKeywords",
        "private static func estimatedGrams(for ingredient: Ingredient?)",
        "private static func estimatedGrams(forName ingredientName: String?)",
        "private static func normalizeIngredientName",
        "private static func extractNumber",
    ]:
        block = slice_block(source, needle)
        # Mechanical transforms, documented in the generated header:
        block = block.replace("private static", "public static")
        block = block.replace("Ingredient?", "ReplayIngredient?")
        blocks.append(block)

    header = f"""\
import Foundation

// GENERATED by scripts/data/evaluate_mass_estimates.py from
// apps/ios/Platform/Persistence/Services/InventoryIntakeService.swift
// at commit {commit}. DO NOT EDIT by hand — re-run the script to regenerate.
//
// Verbatim slice of the production gram estimator. Mechanical transforms
// applied to each block: `private static` -> `public static` (accessibility
// widening only, so the replay executable can call the members), and
// `Ingredient?` -> the minimal `ReplayIngredient?` stand-in so the slice
// compiles off iOS. Everything else (logic, thresholds, keyword tables) is
// byte-identical.

public struct ReplayIngredient {{
  public var typicalUnit: String?
  public init(typicalUnit: String?) {{
    self.typicalUnit = typicalUnit
  }}
}}

public enum EstimatorReplay {{
"""
    body = "\n\n".join(blocks)
    footer = "\n}\n"
    return header + body + footer


def build_examples() -> list[dict]:
    with UNITS_CSV.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    by_unit: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        by_unit[row["unit"]].append(row)
    examples: list[dict] = []
    seen_ids: set[tuple[int, str]] = set()
    for unit in SAMPLE_UNITS:
        family = sorted(
            by_unit.get(unit, []), key=lambda r: (int(r["fdc_id"]), r["portion_description"])
        )
        stride = max(1, len(family) // PER_UNIT_CAP)
        taken = 0
        for row in family[::stride]:
            if taken >= PER_UNIT_CAP:
                break
            key = (int(row["fdc_id"]), row["unit"])
            if key in seen_ids:
                continue
            seen_ids.add(key)
            examples.append(
                {
                    "fdcId": int(row["fdc_id"]),
                    "food": row["food_description"],
                    "portion": row["portion_description"],
                    "unit": row["unit"],
                    "usdaGrams": float(row["gram_weight"]),
                }
            )
            taken += 1
    return examples


def name_bucket(food: str) -> str:
    normalized = food.strip().lower()
    for label, keywords in NAME_BUCKETS:
        if any(k in normalized for k in keywords):
            return label
    return "fallback"


def summarize(name: str, values: list[tuple[float, float, dict]]) -> str:
    relative = [abs(est - truth) / truth for est, truth, _ in values]
    within_25 = sum(1 for r in relative if r <= 0.25)
    within_50 = sum(1 for r in relative if r <= 0.50)
    return (
        f"| {name} | {len(values)} | {statistics.median(relative) * 100:.0f}% "
        f"| {statistics.mean(relative) * 100:.0f}% | {within_25} "
        f"| {within_50} |"
    )


def main() -> int:
    if not ESTIMATOR_SWIFT.exists():
        print(f"estimator source missing: {ESTIMATOR_SWIFT}", file=sys.stderr)
        return 2

    commit = source_commit()
    source = ESTIMATOR_SWIFT.read_text(encoding="utf-8")
    REPLAY_SWIFT.parent.mkdir(parents=True, exist_ok=True)
    REPLAY_SWIFT.write_text(build_replay(source, commit), encoding="utf-8")

    examples = build_examples()
    if len(examples) < 100:
        print(f"only {len(examples)} examples built; need >= 100", file=sys.stderr)
        return 2
    EXAMPLES_JSON.write_text(
        json.dumps(
            {
                "source": {
                    "estimatorFile": str(
                        ESTIMATOR_SWIFT.relative_to(REPO_ROOT)
                    ),
                    "estimatorCommit": commit,
                    "unitsTable": str(UNITS_CSV.relative_to(REPO_ROOT)),
                },
                "examples": examples,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    run = subprocess.run(
        [swift, "run", "--package-path", str(PACKAGE_DIR), "estimator-eval",
         str(EXAMPLES_JSON)],
        capture_output=True,
        text=True,
    )
    if run.returncode != 0:
        print(run.stdout[-4000:], file=sys.stderr)
        print(run.stderr[-4000:], file=sys.stderr)
        return 2
    results = json.loads(run.stdout)["results"]

    # Per-example CSV.
    with EVAL_CSV.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(results[0].keys()) + ["nameArmErrorPct", "unitArmErrorPct"],
            quoting=csv.QUOTE_ALL,
            lineterminator="\r\n",
        )
        writer.writeheader()
        for row in results:
            out = dict(row)
            out["nameArmErrorPct"] = round(
                abs(row["nameArmGrams"] - row["usdaGrams"]) / row["usdaGrams"] * 100, 1
            )
            out["unitArmErrorPct"] = round(
                abs(row["unitArmGrams"] - row["usdaGrams"]) / row["usdaGrams"] * 100, 1
            )
            writer.writerow(out)

    # Arm summaries.
    arms = {
        "nameArm": lambda r: r["nameArmGrams"],
        "unitArm": lambda r: r["unitArmGrams"],
        "unitPrefixedArm": lambda r: r["unitPrefixedArmGrams"],
    }
    summary_rows = {
        arm: [
            (estimate(row), row["usdaGrams"], row)
            for row in results
            if (estimate := arms[arm]) is not None
        ]
        for arm in arms
    }

    # Unit-family medians for the unit arm.
    unit_family: dict[str, list[float]] = defaultdict(list)
    for row in results:
        unit_family[row["unit"]].append(
            abs(row["unitArmGrams"] - row["usdaGrams"]) / row["usdaGrams"]
        )

    # Bucket bias for the name arm.
    bucket_bias: dict[str, list[float]] = defaultdict(list)
    for row in results:
        bucket = name_bucket(row["food"])
        bucket_bias[bucket].append(
            (row["nameArmGrams"] - row["usdaGrams"]) / row["usdaGrams"]
        )

    worst = sorted(
        results,
        key=lambda r: -abs(r["nameArmGrams"] - r["usdaGrams"]) / r["usdaGrams"],
    )[:8]

    lines = [
        "# estimateGrams evaluation vs USDA FNDDS household measures",
        "",
        f"- Estimator: `InventoryIntakeService` (replayed verbatim from source "
        f"blob `{commit[:12]}`; read-only, unmodified)",
        f"- Examples: {len(examples)} source-bound FNDDS portions "
        f"(`estimator_examples.json`, units table `{UNITS_CSV.name}`)",
        f"- Replay executable: `apps/ios/Tools/mass-conversion-check` "
        "(`estimator-eval`)",
        "",
        "## Arm summary",
        "",
        "| Arm | n | Median rel. error | Mean rel. error | Within ±25% | Within ±50% |",
        "|---|---|---|---|---|---|",
    ]
    for arm in arms:
        lines.append(summarize(arm, summary_rows[arm]))

    lines += [
        "",
        "## Unit-arm median relative error by unit family",
        "",
        "| Unit | n | Median rel. error |",
        "|---|---|---|",
    ]
    for unit in sorted(unit_family):
        lines.append(
            f"| {unit} | {len(unit_family[unit])} "
            f"| {statistics.median(unit_family[unit]) * 100:.0f}% |"
        )

    lines += [
        "",
        "## Name-arm bias by keyword bucket (signed, positive = overestimate)",
        "",
        "| Bucket | n | Median signed error |",
        "|---|---|---|",
    ]
    for bucket in sorted(bucket_bias):
        lines.append(
            f"| {bucket} | {len(bucket_bias[bucket])} "
            f"| {statistics.median(bucket_bias[bucket]) * 100:+.0f}% |"
        )

    lines += [
        "",
        "## Worst name-arm examples",
        "",
        "| Food | Portion | USDA g | Estimate g | Error |",
        "|---|---|---|---|---|",
    ]
    for row in worst:
        error = abs(row["nameArmGrams"] - row["usdaGrams"]) / row["usdaGrams"] * 100
        lines.append(
            f"| {row['food']} | {row['portion']} | {row['usdaGrams']:g} "
            f"| {row['nameArmGrams']:g} | {error:.0f}% |"
        )

    lines += [
        "",
        "Reproduce: `python3 scripts/data/evaluate_mass_estimates.py` "
        "(regenerates the replay slice and examples, reruns `estimator-eval` "
        "and `conversion-checks`; add `--verify-report` to byte-verify the "
        "committed reports).",
        "",
    ]
    EVAL_MD.write_text("\n".join(lines), encoding="utf-8")

    checks = run_conversion_checks()
    write_conversion_reports(checks)
    yield_summary = run_yield_sensitivity()
    packing_summary = run_packing_scan()

    print(f"examples: {len(examples)}")
    for arm in arms:
        rel = [
            abs(est - truth) / truth for est, truth, _ in summary_rows[arm]
        ]
        print(
            f"{arm}: n={len(rel)} median={statistics.median(rel) * 100:.0f}% "
            f"mean={statistics.mean(rel) * 100:.0f}% "
            f"within50={sum(1 for r in rel if r <= 0.5)}"
        )
    held = checks["heldout"]
    aggregate = held["aggregate"]
    print(
        f"heldout (leave-one-category-out, {held['categoryCount']} arms): "
        f"n={aggregate['n']} recovered={aggregate['matched']} "
        f"unknown={aggregate['unknown']} "
        f"median={aggregate['medianRelErrPct']:.1f}% "
        f"mean={aggregate['meanRelErrPct']:.1f}% "
        f"within25={aggregate['within25Pct']} within50={aggregate['within50Pct']}"
    )
    for arm in held["arms"]:
        print(
            f"  arm {arm['category']}: n={arm['n']} matched={arm['matched']} "
            f"unknown={arm['unknown']} median={arm['medianRelErrPct']:.1f}%"
        )
    meals = checks["meals"]
    print(
        f"meals (conversion-path plumbing check, not a yield study): "
        f"{meals['fullyConvertedMeals']}/{meals['nMeals']} fully "
        f"converted, conversion rate {meals['ingredientYieldPct']:.1f}%"
    )
    if yield_summary:
        print(
            f"yield sensitivity: {yield_summary['pairCount']} raw/cooked "
            f"pairs, ratio {yield_summary['ratioMin']:.3f}–"
            f"{yield_summary['ratioMedian']:.3f}–{yield_summary['ratioMax']:.3f}, "
            f"missing inputs {yield_summary['missingInputs']}"
        )
    if packing_summary:
        print(
            f"packing scan: {packing_summary['qualifierHits']} qualifier-level "
            "hits in parsed rows; packing generalization unmeasured"
        )
    return 0


def run_conversion_checks() -> dict:
    """Runs the conversion-checks executable (food-group-held-out recovery
    via leave-one-category-out + the 100-meal conversion-path plumbing
    check) and returns its parsed JSON output.

    Release build: leave-one-category-out is O(entries^2) token work
    (~7,300 withheld entries scanned against the full table per arm set);
    release keeps a full run under two minutes where debug takes minutes.
    """
    run = subprocess.run(
        [
            swift,
            "run",
            "-c",
            "release",
            "--package-path",
            str(PACKAGE_DIR),
            "conversion-checks",
        ],
        capture_output=True,
        text=True,
    )
    if run.returncode != 0:
        print(run.stdout[-4000:], file=sys.stderr)
        print(run.stderr[-4000:], file=sys.stderr)
        raise SystemExit(2)
    return json.loads(run.stdout)




def write_conversion_reports(checks: dict) -> None:
    """Writes conversion_checks.json and a human-readable .md summary next to
    the estimator evaluation outputs."""
    checks_path = OUT_DIR / "conversion_checks.json"
    checks_path.write_text(
        json.dumps(checks, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    held = checks["heldout"]
    aggregate = held["aggregate"]
    arms = held["arms"]
    meals = checks["meals"]
    lines = [
        "# Conversion checks: food-group-held-out recovery and conversion-path plumbing",
        "",
        "Both checks run the shipped `MassConversionKit` matcher over the",
        "pinned FNDDS table. Unknown conversions are never fabricated into a",
        "number, so every recovered figure comes from matched evidence.",
        "",
        "## Food-group-held-out recovery (leave-one-WWEIA-category-out)",
        "",
        f"Protocol: {held['protocol']} — {held['categoryCount']} arms.",
        "Withholding the entire category means no other record for the same",
        "food can remain in the lookup while its sibling is queried (the",
        "earlier every-10th-entry split left same-food records in training,",
        "which overstated recovery).",
        "",
        "### Aggregate across arms",
        "",
        f"- Withheld entries: {aggregate['n']} across {held['categoryCount']} arms",
        f"- Recovered by the matcher: {aggregate['matched']} "
        f"({aggregate['exact']} exact, {aggregate['partial']} partial)",
        f"- Unknown (no entry matched): {aggregate['unknown']}",
        f"- Median rel. error: {aggregate['medianRelErrPct']:.1f}% "
        f"(mean {aggregate['meanRelErrPct']:.1f}%)",
        f"- Within ±25%: {aggregate['within25Pct']} · within ±50%: "
        f"{aggregate['within50Pct']}",
        "",
        "Worst matched-elsewhere recoveries (aggregate):",
        "",
        "| Food | Unit | Withheld g | Matched g | Rel. error | Withheld category |",
        "|---|---|---|---|---|---|",
    ]
    for w in aggregate["worst"]:
        lines.append(
            f"| {w['food']} | {w['unit']} | {w['actualGrams']:g} "
            f"| {w['matchedGrams']:g} | {w['relErrPct']:.1f}% "
            f"| {w['withheldCategory']} |"
        )
    lines += [
        "",
        "### Per-category arms (sorted by category name)",
        "",
        "Each row is one leave-one-category-out arm: the entire WWEIA",
        "category was withheld from the lookup and every entry in it was",
        "queried against the remaining table.",
        "",
        "| Category | n | Matched | Unknown | Exact | Partial | Median rel. err | Mean rel. err | Within ±25% | Within ±50% |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]

    def pct(value: float) -> str:
        return f"{value:.1f}%" if value else "—"

    for arm in arms:
        lines.append(
            f"| {arm['category']} | {arm['n']} | {arm['matched']} "
            f"| {arm['unknown']} | {arm['exact']} | {arm['partial']} "
            f"| {pct(arm['medianRelErrPct'])} | {pct(arm['meanRelErrPct'])} "
            f"| {arm['within25Pct']} | {arm['within50Pct']} |"
        )
    lines += [
        "",
        "## 100-meal conversion-path plumbing check (NOT a yield study)",
        "",
        f"Label: {meals['label']}.",
        "",
        f"- Ingredients: {meals['nIngredients']}",
        f"- Converted with evidence: {meals['convertedIngredients']} "
        f"({meals['exactIngredients']} exact, {meals['partialIngredients']} "
        f"partial) — {meals['ingredientYieldPct']:.1f}% conversion rate",
        f"- Unknown: {meals['unknownIngredients']}",
        f"- Fully converted meals: {meals['fullyConvertedMeals']}/{meals['nMeals']}"
        f" — {meals['mealYieldPct']:.1f}% of meals",
        "",
        "Meal queries are intake-style (first three words of the FNDDS",
        "description). Because those words are a token prefix of the source",
        "description, they always overlap it — so this check validates the",
        "end-to-end conversion path (unit choice, lookup, evidence levels)",
        "over census-derived meals. It is plumbing, not a yield study:",
        "successful conversion of generated meal bundles says nothing about",
        "cooking yield. Cooking-yield sensitivity is derived source-bound in",
        "`yield_sensitivity.{json,md}`; real-world coverage of partial user",
        "input is not measured here.",
        "",
    ]
    (OUT_DIR / "conversion_checks.md").write_text(
        "\n".join(lines), encoding="utf-8"
    )


def run_yield_sensitivity() -> dict:
    """Derives source-bound raw-to-cooked yield pairs and their per-unit
    energy/macronutrient consequences.

    Pairs join two survey foods in the same WWEIA category whose normalized
    description stems (state words removed) are equal, one `raw` and one
    `cooked`, sharing a canonical household unit whose per-unit grams differ
    (first household-units row per food+unit, matching the conversion
    table's dedup order). Per-unit nutrient values come from the
    SurveyFoods per-100g anchors (208/203/204/205) of each side; deltas are
    cooked minus raw. Candidates lacking shared units or nutrients are
    returned as explicit missing-input records — never filled.
    """
    if not CACHE_JSON.exists():
        print(
            f"yield-sensitivity arm skipped: cache missing ({CACHE_JSON})",
            file=sys.stderr,
        )
        return {}
    document = json.loads(CACHE_JSON.read_text(encoding="utf-8"))
    foods = document["SurveyFoods"]

    nutrients: dict[int, dict[str, float]] = {}
    for food in foods:
        per100: dict[str, float] = {}
        for nutrient in food.get("foodNutrients") or []:
            number = (nutrient.get("nutrient") or {}).get("number")
            if (
                number in YIELD_NUTRIENT_NUMBERS
                and nutrient.get("amount") is not None
            ):
                per100[YIELD_NUTRIENT_NUMBERS[number]] = float(nutrient["amount"])
        nutrients[food["fdcId"]] = per100

    units_by_food: dict[int, dict[str, float]] = {}
    with UNITS_CSV.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            fid = int(row["fdc_id"])
            unit = row["unit"]
            if unit in units_by_food.setdefault(fid, {}):
                continue  # first row per (food, unit), matching table dedup
            units_by_food[fid][unit] = (
                float(row["gram_weight"]) / float(row["magnitude"])
            )

    pairs, missing = derive_yield_pairs(foods, units_by_food, nutrients)

    enriched = []
    for pair in pairs:
        raw_n = nutrients[pair["rawFdcId"]]
        cooked_n = nutrients[pair["cookedFdcId"]]
        per_unit_raw = {
            key: raw_n[key] * pair["rawGramsPerUnit"] / 100
            for key in ("kcal", "proteinG", "fatG", "carbG")
        }
        per_unit_cooked = {
            key: cooked_n[key] * pair["cookedGramsPerUnit"] / 100
            for key in ("kcal", "proteinG", "fatG", "carbG")
        }
        enriched.append(
            {
                **pair,
                "ratio": round(pair["ratio"], 6),
                "per100gRaw": raw_n,
                "per100gCooked": cooked_n,
                "perUnitRaw": {k: round(v, 6) for k, v in per_unit_raw.items()},
                "perUnitCooked": {
                    k: round(v, 6) for k, v in per_unit_cooked.items()
                },
                "perUnitDelta": {
                    k: round(per_unit_cooked[k] - per_unit_raw[k], 6)
                    for k in ("kcal", "proteinG", "fatG", "carbG")
                },
            }
        )

    ratios = [p["ratio"] for p in enriched]
    kcal_deltas = [p["perUnitDelta"]["kcal"] for p in enriched]
    summary = {
        "pairCount": len(enriched),
        "categoriesCovered": len({p["category"] for p in enriched}),
        "ratioMin": min(ratios) if ratios else None,
        "ratioMedian": statistics.median(ratios) if ratios else None,
        "ratioMax": max(ratios) if ratios else None,
        "kcalPerUnitDeltaMin": min(kcal_deltas) if kcal_deltas else None,
        "kcalPerUnitDeltaMedian": (
            statistics.median(kcal_deltas) if kcal_deltas else None
        ),
        "kcalPerUnitDeltaMax": max(kcal_deltas) if kcal_deltas else None,
        "missingInputs": len(missing),
        "missingInputReasons": dict(
            sorted(Counter(m["reason"] for m in missing).items())
        ),
    }
    payload = {
        "protocol": (
            "raw-to-cooked survey-food pairs: same WWEIA category, same "
            "normalized description stem (state words removed), shared "
            "canonical household unit with differing per-unit grams; "
            "ratio = cooked grams per unit / raw grams per unit; per-unit "
            "nutrients from SurveyFoods per-100g anchors (208 kcal, 203 "
            "protein, 204 fat, 205 carbohydrate) of each side"
        ),
        "inputs": {
            "surveyJsonSha256": (
                "2e7eb9fda92adf1d4d784dba5eaa3a7fd4418cd86ccff383c7c9294d79e9b808"
            ),
            "unitsTable": str(UNITS_CSV.relative_to(REPO_ROOT)),
            "perUnitGramsRule": (
                "first fndds_household_units.csv row per (fdc_id, unit), the "
                "same first-occurrence order the conversion table dedups by"
            ),
        },
        "summary": summary,
        "pairs": enriched,
        "missingInputs": missing,
    }
    YIELD_JSON.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    lines = [
        "# Cooking-yield sensitivity (source-bound raw/cooked pairs)",
        "",
        f"Protocol: {payload['protocol']}.",
        "",
        f"- Pairs: {summary['pairCount']} across "
        f"{summary['categoriesCovered']} WWEIA categories",
        "- Ratio spread (cooked g/unit ÷ raw g/unit): "
        f"{summary['ratioMin']:.3f} – {summary['ratioMedian']:.3f} (median) "
        f"– {summary['ratioMax']:.3f}",
        "- Per-unit kcal delta (cooked − raw): "
        f"{summary['kcalPerUnitDeltaMin']:+.1f} – "
        f"{summary['kcalPerUnitDeltaMedian']:+.1f} (median) – "
        f"{summary['kcalPerUnitDeltaMax']:+.1f}",
        f"- Missing inputs (explicit, never filled): "
        f"{summary['missingInputs']}"
        + (
            f" — {summary['missingInputReasons']}"
            if summary["missingInputs"]
            else ""
        ),
        "",
        "The ratio is a mass-yield factor observed between two survey foods",
        "of the same stem, not a universal cooking rule: it conflates water",
        "loss/gain with per-100g density changes, and per-unit macro deltas",
        "show the combined effect of both (per-unit grams × per-100g",
        "nutrients). Nothing in MassConversionKit applies a yield factor;",
        "this arm quantifies how much per-unit energy and macros move",
        "between raw and cooked forms of the same food stem.",
        "",
        "This arm is NOT the 100-meal check: converting generated three-food",
        "bundles is conversion-path plumbing (`conversion_checks.md`), not a",
        "yield study.",
        "",
        "| Category | Raw food | g/unit | Cooked food | g/unit | Ratio | Δ kcal/unit | Δ protein g/unit | Δ fat g/unit | Δ carb g/unit |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for p in enriched:
        lines.append(
            f"| {p['category']} | {p['rawFood']} | {p['rawGramsPerUnit']:g} "
            f"| {p['cookedFood']} | {p['cookedGramsPerUnit']:g} "
            f"| {p['ratio']:.3f} | {p['perUnitDelta']['kcal']:+.1f} "
            f"| {p['perUnitDelta']['proteinG']:+.1f} "
            f"| {p['perUnitDelta']['fatG']:+.1f} "
            f"| {p['perUnitDelta']['carbG']:+.1f} |"
        )
    if missing:
        lines += [
            "",
            "## Missing inputs (explicit)",
            "",
            "| Category | Raw food | Cooked food | Unit | Reason |",
            "|---|---|---|---|---|",
        ]
        for m in missing:
            lines.append(
                f"| {m['category']} | {m['rawFood']} | {m['cookedFood']} "
                f"| {m.get('unit', '—')} | {m['reason']} |"
            )
    YIELD_MD.write_text("\n".join(lines), encoding="utf-8")
    return summary


def run_packing_scan() -> dict:
    """Scans the full FNDDS corpus portion description+modifier text for
    packing terms and reports why packing generalization stays unmeasured:
    container words appear as quantity units, and qualifier-level hits lose
    the conversion table's dedup, so the pinned table carries 0 packing
    labels. Packing matching is exercised only by synthetic unit tests."""
    if not CACHE_JSON.exists():
        print(
            f"packing arm skipped: cache missing ({CACHE_JSON})", file=sys.stderr
        )
        return {}
    document = json.loads(CACHE_JSON.read_text(encoding="utf-8"))
    scan = scan_packing_terms(document["SurveyFoods"])

    table = json.loads(CONVERSION_TABLE_JSON.read_text(encoding="utf-8"))
    table_labels = {
        "state": sum(1 for p in table["portions"] if p.get("state")),
        "packing": sum(1 for p in table["portions"] if p.get("packing")),
    }

    def table_entry(fdc_id: int, unit: str, magnitude: float) -> dict | None:
        for portion in table["portions"]:
            if (
                portion["fdcId"] == fdc_id
                and portion["unit"] == unit
                and portion["magnitude"] == magnitude
            ):
                return portion
        return None

    survival_checks = []
    survivors = 0
    for hit in scan["qualifierPackingHits"]:
        entry = table_entry(hit["fdcId"], hit["unit"], hit["magnitude"])
        survived = bool(entry and entry.get("packing"))
        survivors += 1 if survived else 0
        survival_checks.append(
            {
                **hit,
                "tableEntryPacking": (entry or {}).get("packing"),
                "survivesIntoTable": survived,
            }
        )

    statement = (
        "FNDDS attaches no packing evidence to household portions that "
        "survives into the pinned conversion table: container words appear "
        "as quantity units ('1 can', '1 package'), and qualifier-level "
        "hits are absent from the table after (food, unit, magnitude) "
        "dedup. The table carries "
        f"{table_labels['packing']} packing labels; packing matching in "
        "MassConversionKit is exercised only by synthetic unit tests, so "
        "packing generalization is UNMEASURED."
    )
    payload = {
        "protocol": (
            "word-boundary scan of FNDDS portionDescription + modifier text "
            "over the full corpus"
        ),
        "terms": list(PACKING_SCAN_TERMS),
        "corpus": {
            "surveyFoods": len(document["SurveyFoods"]),
            "portionsScanned": scan["portionsScanned"],
        },
        "termCountsAllPortions": scan["termCounts"],
        "parsedHouseholdRows": scan["parsedHouseholdRows"],
        "termCountsParsedHouseholdRows": scan["parsedTermCounts"],
        "qualifierPackingHits": survival_checks,
        "conversionTableLabels": table_labels,
        "qualifierHitsSurvivingTableDedup": survivors,
        "conclusion": statement,
    }
    PACKING_JSON.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    lines = [
        "# Packing-evidence scan (why packing generalization is unmeasured)",
        "",
        f"Protocol: {payload['protocol']}.",
        "",
        f"- Corpus: {payload['corpus']['surveyFoods']} survey foods, "
        f"{payload['corpus']['portionsScanned']} portions scanned, "
        f"{scan['parsedHouseholdRows']} parse into canonical household units",
        "",
        "## Raw term counts over the full corpus portion text",
        "",
        "| Term | All portions | Parsed household rows |",
        "|---|---|---|",
    ]
    all_counts = scan["termCounts"]
    parsed_counts = scan["parsedTermCounts"]
    for term in PACKING_SCAN_TERMS:
        if all_counts.get(term) or parsed_counts.get(term):
            lines.append(
                f"| {term} | {all_counts.get(term, 0)} "
                f"| {parsed_counts.get(term, 0)} |"
            )
    lines += [
        "",
        "Container words hit the corpus overwhelmingly as quantity units —",
        '\"1 can (5 oz) yields\", \"1 package (4.5 oz)\" — which is the',
        "portion's own unit, not a packing qualifier on the grams.",
        "",
        "## Qualifier-level hits in parsed household rows",
        "",
        f"{len(scan['qualifierPackingHits'])} parsed row(s) would classify as",
        "packing via qualifier text:",
        "",
    ]
    for hit in survival_checks:
        lines.append(
            f"- fdcId {hit['fdcId']} '{hit['food']}' — "
            f"'{hit['portionDescription']}' → {hit['classification']}; "
            f"survives into the conversion table: "
            f"{hit['survivesIntoTable']}"
            + (
                ""
                if hit["survivesIntoTable"]
                else " (dedup keeps an earlier same-key row)"
            )
        )
    lines += [
        "",
        f"Conversion-table labels: {table_labels['state']} state, "
        f"{table_labels['packing']} packing.",
        "",
        "## Conclusion",
        "",
        statement,
        "",
        "Packing matching is exercised only by synthetic unit tests",
        "(`testCannedQueryPrefersCannedPacking` and friends); packing",
        "generalization is unmeasured against real data.",
        "",
    ]
    PACKING_MD.write_text("\n".join(lines), encoding="utf-8")
    return {"qualifierHits": len(scan["qualifierPackingHits"])}



def verify_report() -> int:
    """Regenerates every committed output and byte-compares it against the
    committed files. Exits 1 naming the drift on any mismatch."""
    # The extractor owns mass_conversion_table.json; the cache may not exist
    # in a fresh clone, so only re-verify when extraction is reproducible.
    committed = {
        path.name: path.read_bytes()
        for path in [
            EXAMPLES_JSON,
            EVAL_CSV,
            EVAL_MD,
            OUT_DIR / "conversion_checks.json",
            OUT_DIR / "conversion_checks.md",
            OUT_DIR / "yield_sensitivity.json",
            OUT_DIR / "yield_sensitivity.md",
            OUT_DIR / "packing_scan.json",
            OUT_DIR / "packing_scan.md",
            OUT_DIR / "mass_conversion_table.json",
        ]
    }
    if CACHE_JSON.exists():
        import extract_household_measures as extractor

        extractor_code = subprocess.run(
            [sys.executable, str(extractor.__file__)],
            capture_output=True,
            text=True,
        )
        if extractor_code.returncode != 0:
            print(extractor_code.stderr[-4000:], file=sys.stderr)
            return 2

    main()  # regenerates the estimator reports and conversion checks
    drifted = []
    for name, expected in committed.items():
        actual = (OUT_DIR / name).read_bytes()
        if actual != expected:
            drifted.append(name)
    if drifted:
        print(
            "report drift detected (regenerated output differs from "
            "committed files): " + ", ".join(sorted(drifted)),
            file=sys.stderr,
        )
        return 1
    print("verify-report: all committed outputs byte-identical")
    return 0


def main_with_args() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify-report",
        action="store_true",
        help="regenerate every committed output and byte-compare it "
        "against the committed files; exit 1 on drift",
    )
    args = parser.parse_args()
    return verify_report() if args.verify_report else main()


if __name__ == "__main__":
    raise SystemExit(main_with_args())
