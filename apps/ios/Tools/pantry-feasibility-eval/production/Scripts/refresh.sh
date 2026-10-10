#!/usr/bin/env bash
# Copies the real production sources this replay exercises into the package so
# the harness runs the actual app code, not a fork.
#
# Run from anywhere: bash Scripts/refresh.sh (paths are package-relative).
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_ROOT="../../.."
REAL="Sources/PantryFeasibilityProduction/Real"
rm -rf "$REAL"
mkdir -p "$REAL"

copy() {
  local src="$IOS_ROOT/$1"
  [ -f "$src" ] || { echo "missing real source: $src" >&2; exit 1; }
  cp "$src" "$REAL/"
}

# Persistence sources exercised by the replay (paths relative to apps/ios).
copy Platform/Persistence/Database/Migrations.swift
copy Platform/Persistence/Repository/RecipeRepository.swift
copy Platform/Persistence/Repository/RecipeScoring.swift
copy Platform/Persistence/Services/NutritionService.swift
copy Platform/Persistence/Services/HealthScoringService.swift
copy Platform/Persistence/Services/PersonalizationService.swift

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
copy Feature/Home/HomeDashboardModels.swift

echo "refreshed $(ls "$REAL" | wc -l) real sources into $REAL"
