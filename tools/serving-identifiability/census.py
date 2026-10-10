"""Source-bound field census for the serving-identifiability study.

Binds every schema concept to the exact source location it comes from on
feat/meal-photo-confirmation-v1. `verify_census()` re-reads the source files
and checks each token at its recorded line; tests run that check so the census
fails loudly if the source drifts.

Run `python3 tools/serving-identifiability/census.py` to regenerate census.json.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import bundled
import schema
import witnesses

REPO_ROOT = Path(__file__).resolve().parents[2]
CENSUS_JSON = Path(__file__).resolve().parent / "census.json"

BASE_BRANCH = "feat/meal-photo-confirmation-v1"

#: concept -> (file, 1-based line, token, role)
CENSUS: list[dict] = [
    {
        "concept": "declared recipe servings",
        "source_field": "Recipe.servings",
        "file": "apps/ios/Domain/Models/Recipe.swift",
        "line": 58,
        "token": "var servings: Int",
        "role": "denominator (recipe metadata)",
        "schema_field": "declared_servings",
    },
    {
        "concept": "consumed servings (confirmation state)",
        "source_field": "MealFinalizationViewModel.servings",
        "file": "apps/ios/Feature/Finalization/MealFinalizationViewModel.swift",
        "line": 9,
        "token": "var servings: Int = 1",
        "role": "target (what the plate weight must identify)",
        "schema_field": "consumed_servings",
    },
    {
        "concept": "consumed servings passed to the log",
        "source_field": "servingsConsumed: servings",
        "file": "apps/ios/Feature/Finalization/MealFinalizationViewModel.swift",
        "line": 58,
        "token": "servingsConsumed: servings",
        "role": "target (flows into recordCooking/applyConsumption)",
        "schema_field": "consumed_servings",
    },
    {
        "concept": "portion multiplier (user-confirmed)",
        "source_field": "MealLogService.logMeal portionMultiplier",
        "file": "apps/ios/Platform/Persistence/Services/MealLogService.swift",
        "line": 74,
        "token": "portionMultiplier: Double = 1.0,",
        "role": "observation (confirmed at log time, not observable from the plate)",
        "schema_field": "portion_multiplier",
    },
    {
        "concept": "portion multiplier validity guard",
        "source_field": "MealLogError.invalidPortionMultiplier",
        "file": "apps/ios/Platform/Persistence/Services/MealLogService.swift",
        "line": 79,
        "token": "guard portionMultiplier.isFinite, portionMultiplier > 0 else {",
        "role": "validity rule (mirrored as InvalidPortionMultiplier)",
        "schema_field": "portion_multiplier",
    },
    {
        "concept": "servings clamp at log time",
        "source_field": "safeServings",
        "file": "apps/ios/Platform/Persistence/Services/MealLogService.swift",
        "line": 78,
        "token": "let safeServings = max(1, servingsConsumed)",
        "role": "validity rule (target domain is positive integers)",
        "schema_field": "consumed_servings",
    },
    {
        "concept": "forward model: share of the recipe one log covers",
        "source_field": "InventoryRepository.servingFactor",
        "file": "apps/ios/Platform/Persistence/Repository/InventoryRepository.swift",
        "line": 317,
        "token": "Double(max(0, servingsConsumed)) * portionMultiplier / Double(max(recipeServings, 1))",
        "role": "forward model (transcribed exactly in schema.serving_factor)",
        "schema_field": "(forward model)",
    },
    {
        "concept": "consumption clamp",
        "source_field": "safeServingsConsumed",
        "file": "apps/ios/Platform/Persistence/Repository/InventoryRepository.swift",
        "line": 255,
        "token": "let safeServingsConsumed = max(0, servingsConsumed)",
        "role": "validity rule",
        "schema_field": "consumed_servings",
    },
    {
        "concept": "batch grams per ingredient (required)",
        "source_field": "RecipeIngredient.quantityGrams",
        "file": "apps/ios/Domain/Models/Recipe.swift",
        "line": 97,
        "token": "var quantityGrams: Double",
        "role": "world fact (bundled per-ingredient grams; sum = declared batch)",
        "schema_field": "batch_grams (latent)",
    },
    {
        "concept": "required-only scaling",
        "source_field": "MealBreakdownContent.make doc comment",
        "file": "apps/ios/Feature/Estimate/ReverseScanResultsSections.swift",
        "line": 63,
        "token": "Only required ingredients are listed, with the scaling `InventoryRepository.applyConsumption`",
        "role": "modeling decision (batch = sum of required ingredient grams)",
        "schema_field": "batch_grams (latent)",
    },
    {
        "concept": "bundled declared servings",
        "source_field": "RecipeArray.servings",
        "file": "apps/ios/Platform/Persistence/Bundle/BundledDataLoader.swift",
        "line": 51,
        "token": "let servings: Int",
        "role": "denominator (bundled metadata; data.json values are 1..3)",
        "schema_field": "declared_servings",
    },
    {
        "concept": "confirmation policy statement",
        "source_field": "MealPhotoConfirmationPolicy doc comment",
        "file": "apps/ios/FeatureLogic/Recipe/MealPhotoConfirmationPolicy.swift",
        "line": 6,
        "token": "logged amounts follow the dish, servings and portion the user confirms.",
        "role": "observation model statement (dish/servings/portion are the confirmable evidence)",
        "schema_field": "recipe_identity, consumed_servings, portion_multiplier",
    },
    {
        "concept": "bundled recipe metadata",
        "source_field": "data.json recipes array",
        "file": "apps/ios/Resources/data.json",
        "line": 604,
        "token": '"recipes": [',
        "role": "family metadata source (166 recipes with ingredient gram quantities)",
        "schema_field": "batch_grams, declared_servings",
    },
    {
        "concept": "weighed plate total",
        "source_field": "(absent from app source)",
        "file": None,
        "line": None,
        "token": None,
        "role": (
            "external observation: no scale/plate-weight input exists in the app "
            "source on this branch, so the plate weight enters only as this "
            "study's external observation"
        ),
        "schema_field": "plate_weight_g",
    },
]


def verify_census(repo_root: Path = REPO_ROOT) -> list[str]:
    """Re-read each bound source file and check the token at the recorded
    line. Returns a list of problems (empty = census verifies)."""
    problems = []
    for entry in CENSUS:
        if entry["file"] is None:
            continue
        path = repo_root / entry["file"]
        if not path.exists():
            problems.append(f"{entry['file']}: file not found")
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        line_no = entry["line"]
        if line_no < 1 or line_no > len(lines):
            problems.append(f"{entry['file']}:{line_no}: line out of range ({len(lines)} lines)")
            continue
        actual = lines[line_no - 1].strip()
        token = entry["token"].strip()
        if token not in actual:
            problems.append(
                f"{entry['file']}:{line_no}: token not found on that line\n"
                f"  expected: {token!r}\n  actual:   {actual!r}"
            )
    return problems


def _git_commit() -> str:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        return out.stdout.strip()
    except Exception:  # pragma: no cover - census still builds outside a repo
        return "unknown"


def build() -> dict:
    """Assemble the census document (schema registry + source bindings +
    witness counts). Deterministic."""
    _ = witnesses.witness_counts()  # asserts the hand numbers first
    registry = {
        "target": {
            "field": schema.TARGET_FIELD,
            "type": "positive int",
            "source": "MealFinalizationViewModel.servings -> servingsConsumed",
        },
        "observations": [
            {"field": name, "absent_value": "None", "role": role}
            for name, role in [
                (
                    "plate_weight_g",
                    "weighed plate total (external observation; exact grams at the scale resolution)",
                ),
                ("recipe_identity", "revealed Recipe.id, or None when the recipe is unknown"),
                ("declared_servings", "revealed Recipe.servings, or None when not revealed"),
                ("portion_multiplier", "user-confirmed portion, or None when unconfirmed"),
                ("reference_weight_g", "explicit per-serving weight of this cook, or None"),
                ("scale_resolution_g", "kitchen-scale readout resolution (constructed: 5 g)"),
            ]
        ],
        "world_facts": [
            "recipe_id",
            "title",
            "declared_servings",
            "batch_grams",
            "consumed_servings (target)",
            "portion_multiplier",
        ],
        "leak_rule": "observation keys may never contain the target field; enforced by schema.find_outcome_leak",
    }
    return {
        "study": "serving-identifiability",
        "base_branch": BASE_BRANCH,
        "base_commit": _git_commit(),
        "data_json_sha256": bundled.data_json_sha256(),
        "schema_registry": registry,
        "source_bindings": CENSUS,
        "witness_counts": witnesses.witness_counts(),
    }


def main() -> None:
    doc = build()
    problems = verify_census()
    if problems:
        raise SystemExit("census does not verify against source:\n" + "\n".join(problems))
    doc["verification"] = "pass"
    CENSUS_JSON.write_text(json.dumps(doc, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(f"wrote {CENSUS_JSON}")


if __name__ == "__main__":
    main()
