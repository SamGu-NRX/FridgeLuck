#!/bin/sh
# Recreates the Sources/RecipeQuantityReviewCheck symlinks into the app's existing
# sources. Nothing is forked: every file under test is the real production source.
# Run once from the package root before `swift test` (the linked files are not
# committed — they are generated here).
set -eu
cd "$(dirname "$0")"

LINK_DIR="Sources/RecipeQuantityReviewCheck"
mkdir -p "$LINK_DIR"

# Paths are relative to $LINK_DIR (../../.. = this package root, ../../../../ = apps/ios).
for f in \
  "../../../../Domain/Models/Recipe.swift" \
  "../../../../Domain/Models/Ingredient.swift" \
  "../../../../Domain/Models/IngredientSwap.swift" \
  "../../../../Domain/Models/HealthProfile.swift" \
  "../../../../Domain/Models/UserProgress.swift" \
  "../../../../Platform/Persistence/Repository/RecipeRepository.swift" \
  "../../../../Platform/Persistence/Repository/RecipeScoring.swift" \
  "../../../../Platform/Persistence/Services/NutritionService.swift" \
  "../../../../Platform/Persistence/Services/SubstitutionService.swift" \
  "../../../../Platform/Persistence/Services/HealthScoringService.swift" \
  "../../../../Platform/Persistence/Services/PersonalizationService.swift" \
  "../../../../Platform/Persistence/Database/Migrations.swift" \
  "../../../../FeatureLogic/RecipeQuantityReview/RecipeQuantityReviewModels.swift" \
  "../../../../FeatureLogic/RecipeQuantityReview/RecipeQuantityReviewCalculator.swift" \
  "../../../../FeatureLogic/RecipeQuantityReview/RecipeQuantityReviewSession.swift"
do
  ln -sfn "$f" "$LINK_DIR/$(basename "$f")"
done

echo "Linked $(ls -1 "$LINK_DIR" | wc -l) production sources into $LINK_DIR"
