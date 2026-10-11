#!/usr/bin/env bash
# Recreates the Sources/FridgeLuck symlinks into the real app sources. Idempotent: run
# any time. SwiftPM only compiles sources under the package root, so the harness reaches
# the repo's real files through these relative symlinks instead of copied snapshots.
set -euo pipefail

cd "$(dirname "$0")"

link_src() {
  ln -sfn "../../../../$2" "Sources/FridgeLuck/$1"
}

# Domain models + ports (Foundation/GRDB-portable only).
link_src DashboardModels.swift "Domain/Models/DashboardModels.swift"
link_src HealthProfile.swift "Domain/Models/HealthProfile.swift"
link_src Ingredient.swift "Domain/Models/Ingredient.swift"
link_src IngredientSwap.swift "Domain/Models/IngredientSwap.swift"
link_src Inventory.swift "Domain/Models/Inventory.swift"
link_src Recipe.swift "Domain/Models/Recipe.swift"
link_src UserProgress.swift "Domain/Models/UserProgress.swift"
link_src AppleHealthServicing.swift "Domain/Ports/AppleHealthServicing.swift"
link_src AppPermissionCenterMapping.swift "FeatureLogic/Permissions/AppPermissionCenterMapping.swift"

# Persistence.
link_src Migrations.swift "Platform/Persistence/Database/Migrations.swift"
link_src IngredientRepository.swift "Platform/Persistence/Repository/IngredientRepository.swift"
link_src InventoryRepository.swift "Platform/Persistence/Repository/InventoryRepository.swift"
link_src RecipeRepository.swift "Platform/Persistence/Repository/RecipeRepository.swift"
link_src RecipeScoring.swift "Platform/Persistence/Repository/RecipeScoring.swift"
link_src UserDataRepository.swift "Platform/Persistence/Repository/UserDataRepository.swift"
link_src MealConsumptionPlan.swift "Platform/Persistence/Services/MealConsumptionPlan.swift"
link_src MealLogService.swift "Platform/Persistence/Services/MealLogService.swift"
link_src MealLogSyncCoordinator.swift "Platform/Persistence/Services/MealLogSyncCoordinator.swift"
link_src MealCorrectionService.swift "Platform/Persistence/Services/MealCorrectionService.swift"
link_src MealRevisionSeams.swift "Platform/Persistence/Services/MealRevisionSeams.swift"
link_src NutritionSnapshotService.swift "Platform/Persistence/Services/NutritionSnapshotService.swift"
link_src NutritionService.swift "Platform/Persistence/Services/NutritionService.swift"
link_src HealthScoringService.swift "Platform/Persistence/Services/HealthScoringService.swift"
link_src PersonalizationService.swift "Platform/Persistence/Services/PersonalizationService.swift"
link_src HomeDashboardModels.swift "Feature/Home/HomeDashboardModels.swift"

echo "bootstrap: $(find Sources/FridgeLuck -type l | wc -l | tr -d ' ') sources linked"
