#!/usr/bin/env bash
# Copies the real production persistence sources, the real bundled-refresh
# tests, and the shipped bundle resources into this package so the tests
# compile and run against the actual app code, not a fork.
#
# Run from anywhere: bash Scripts/refresh.sh (paths are package-relative).
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_ROOT="../.."
REAL="Sources/FridgeLuck/Real"
copy() {
  local src="$IOS_ROOT/$1"
  [ -f "$src" ] || { echo "missing real source: $src" >&2; exit 1; }
  cp "$src" "$REAL/"
}

rm -rf "$REAL"
mkdir -p "$REAL"

# The full persistence layer minus the five services bound to Apple-only
# frameworks (HealthKit, UIKit, os.log): AppleHealthService,
# MealLogSyncCoordinator, ImageStorageService, MealLogService,
# ConfidenceLearningService.
copy Platform/Persistence/Bundle/BundleOwnership.swift
copy Platform/Persistence/Bundle/BundledDataLoader.swift
copy Platform/Persistence/Bundle/BundledDataLoaderRecipeHydration.swift
copy Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift
copy Platform/Persistence/Bundle/BundledDataRefresher.swift
copy Platform/Persistence/Bundle/BundledDataValidator.swift
copy Platform/Persistence/Bundle/LegacyBundlePins.swift
copy Platform/Persistence/Database/AppDatabase.swift
copy Platform/Persistence/Database/Migrations.swift
copy Platform/Persistence/Repository/IngredientRepository.swift
copy Platform/Persistence/Repository/InventoryRepository.swift
copy Platform/Persistence/Repository/NotificationRuleRepository.swift
copy Platform/Persistence/Repository/RecipeRepository.swift
copy Platform/Persistence/Repository/RecipeScoring.swift
copy Platform/Persistence/Repository/UserDataRepository.swift
copy Platform/Persistence/Services/DishEstimateService.swift
copy Platform/Persistence/Services/HealthScoringService.swift
copy Platform/Persistence/Services/NutritionService.swift
copy Platform/Persistence/Services/NutritionSnapshotService.swift
copy Platform/Persistence/Services/PantryAssumptionService.swift
copy Platform/Persistence/Services/PersonalizationService.swift
copy Platform/Persistence/Services/SpoilageService.swift
copy Platform/Persistence/Services/SubstitutionService.swift
copy Platform/Persistence/Static/USDAIngredientNutritionStaticData.swift

# Domain/feature models the persistence layer references.
copy Domain/Models/Ingredient.swift
copy Domain/Models/IngredientSwap.swift
copy Domain/Models/Inventory.swift
copy Domain/Models/Recipe.swift
copy Domain/Models/DashboardModels.swift
copy Domain/Models/DishTemplate.swift
copy Domain/Models/HealthProfile.swift
copy Domain/Models/UserProgress.swift
copy Domain/Models/NotificationModels.swift
copy Domain/Models/PantryAssumption.swift
copy Domain/Allergens/AllergenGroupMembership.swift
copy Feature/Home/HomeDashboardModels.swift

# The real bundled-refresh test suite (21 tests, including the changed-bundle
# Double.bitPattern invariance check), verbatim from the app test target.
TEST_REAL="Tests/FridgeLuckCheckTests/Real"
rm -rf "$TEST_REAL"
mkdir -p "$TEST_REAL"
cp "$IOS_ROOT/Tests/BundledDataRefreshTests.swift" "$TEST_REAL/"

# The shipped resources the launch-path tests read through Bundle.main.
FIX="Tests/FridgeLuckCheckTests/Fixtures"
rm -rf "$FIX/data.json" "$FIX/LegacyBundles" "$FIX/usda_ingredient_catalog.sqlite"
mkdir -p "$FIX"
cp "$IOS_ROOT/Resources/data.json" "$FIX/data.json"
cp -R "$IOS_ROOT/Resources/LegacyBundles" "$FIX/LegacyBundles"
cp "$IOS_ROOT/Resources/usda_ingredient_catalog.sqlite" "$FIX/usda_ingredient_catalog.sqlite"

echo "refreshed $(ls "$REAL" | wc -l) real sources, the real test suite, and the bundle fixtures"
