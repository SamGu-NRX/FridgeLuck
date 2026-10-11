#!/usr/bin/env bash
# Copies the real production sources into this package so the tests compile
# and run against the actual app code, not a fork.
#
# Run from anywhere: bash Scripts/refresh.sh (paths are package-relative).
set -euo pipefail
cd "$(dirname "$0")/.."

IOS_ROOT="../.."
REAL="Sources/ProgressFlowCheck/Real"
rm -rf "$REAL"
mkdir -p "$REAL"

copy() {
  local src="$IOS_ROOT/$1"
  [ -f "$src" ] || { echo "missing real source: $src" >&2; exit 1; }
  cp "$src" "$REAL/"
}

# Strips one module import that has no Linux counterpart in this check
# package (the staged AppPermissionCenterMapping.swift provides the real
# PermissionStatus type it needs).
copy_import_stripped() {
  local src="$IOS_ROOT/$1"
  [ -f "$src" ] || { echo "missing real source: $src" >&2; exit 1; }
  grep -v '^import FLFeatureLogic$' "$src" > "$REAL/$(basename "$src")"
}

# Persistence sources under test (paths relative to apps/ios).
copy Platform/Persistence/Database/Migrations.swift
copy Platform/Persistence/Repository/UserDataRepository.swift
copy Platform/Persistence/Services/NutritionSnapshotService.swift
copy Platform/Persistence/Services/NutritionService.swift
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

# Health port: real protocol shape, minus the FLFeatureLogic import.
copy_import_stripped Domain/Ports/AppleHealthServicing.swift
copy FeatureLogic/Permissions/AppPermissionCenterMapping.swift

# Progress sources under test (UI-free read model, range state, policies).
copy Feature/Progress/ProgressReadModel.swift
copy Feature/Progress/ProgressRangeState.swift
copy Feature/Progress/ProgressRangeCoordinator.swift
copy Feature/Progress/ProgressFlowPolicy.swift

echo "refreshed $(ls "$REAL" | wc -l) real sources into $REAL"
