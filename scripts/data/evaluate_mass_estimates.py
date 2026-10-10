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
  4. Writes estimator_examples.json, estimator_evaluation.csv, and
     estimator_evaluation.md under reference/household_measures/.

The estimator file itself is never modified.
"""

from __future__ import annotations

import csv
import json
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = REPO_ROOT / "scripts" / "data"
UNITS_CSV = DATA_DIR / "reference" / "household_measures" / "fndds_household_units.csv"
EXAMPLES_JSON = (
    DATA_DIR / "reference" / "household_measures" / "estimator_examples.json"
)
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

SWIFT = "/home/user/swift612/usr/bin/swift"

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
    return subprocess.run(
        ["git", "rev-parse", "HEAD"],
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
        [SWIFT, "run", "--package-path", str(PACKAGE_DIR), "estimator-eval",
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
        f"- Estimator: `InventoryIntakeService` (replayed verbatim at commit `{commit}`;"
        " read-only, unmodified)",
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
        "(regenerates the replay slice and examples, reruns `estimator-eval`).",
        "",
    ]
    EVAL_MD.write_text("\n".join(lines), encoding="utf-8")

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
