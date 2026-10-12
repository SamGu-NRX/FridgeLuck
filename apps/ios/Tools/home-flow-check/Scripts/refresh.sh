#!/usr/bin/env bash
# Copies the real production Home flow and persistence sources into this package
# so the tests compile and run against the actual app code, not a fork.
#
# Run from anywhere: bash Scripts/refresh.sh (paths are package-relative).
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_ROOT="../.."
REAL="Sources/HomeFlowCheck/Real"
rm -rf "$REAL"
mkdir -p "$REAL"

copy() {
  local src="$IOS_ROOT/$1"
  [ -f "$src" ] || { echo "missing real source: $src" >&2; exit 1; }
  cp "$src" "$REAL/"
}

# Home flow sources under test (paths relative to apps/ios).
copy Feature/Home/HomeFlowModels.swift
copy Feature/Home/HomeFlowReadModel.swift
copy Feature/Home/HomeDashboardModels.swift

# Persistence sources the flow layer consumes.
copy Platform/Persistence/Database/Migrations.swift
copy Platform/Persistence/Repository/UserDataRepository.swift
copy Platform/Persistence/Repository/InventoryRepository.swift
copy Platform/Persistence/Repository/RecipeRepository.swift
copy Platform/Persistence/Repository/RecipeScoring.swift
copy Platform/Persistence/Repository/IngredientRepository.swift
copy Platform/Persistence/Services/PersonalizationService.swift
copy Platform/Persistence/Services/SpoilageService.swift
copy Platform/Persistence/Services/NutritionSnapshotService.swift
copy Platform/Persistence/Services/NutritionService.swift
copy Platform/Persistence/Services/HealthScoringService.swift

# Domain/feature models the persistence layer references.
copy Domain/Models/Ingredient.swift
copy Domain/Models/IngredientSwap.swift
copy Domain/Models/Inventory.swift
copy Domain/Models/Recipe.swift
copy Domain/Models/DashboardModels.swift
copy Domain/Models/DishTemplate.swift
copy Domain/Models/HealthProfile.swift
copy Domain/Models/UserProgress.swift
copy Domain/Allergens/AllergenGroupMembership.swift

# The real RecommendationPolicy lives in the FLFeatureLogic framework target,
# which does not exist on Linux; the file itself is Foundation-only, so it is
# copied in like every other real source.
copy FeatureLogic/Recommendation/RecommendationPolicy.swift

echo "refreshed $(ls "$REAL" | wc -l) real sources into $REAL"
