import Foundation
import os

private let mealLogSyncLogger = Logger(subsystem: "samgu.FridgeLuck", category: "MealLogSync")

@MainActor
final class MealLogSyncCoordinator {
  private let appleHealthService: AppleHealthServicing
  private let nutritionService: NutritionService
  private let recipeRepository: RecipeRepository

  init(
    appleHealthService: AppleHealthServicing,
    nutritionService: NutritionService,
    recipeRepository: RecipeRepository
  ) {
    self.appleHealthService = appleHealthService
    self.nutritionService = nutritionService
    self.recipeRepository = recipeRepository
  }

  /// Writes a logged meal to Apple Health when the user has allowed it, scaled by the
  /// servings and portion eaten. The per-serving numbers are the ones Progress reports for
  /// the same history row (`UserDataRepository.computeConsumedMacros`): a catalog-linked meal
  /// reads the snapshot frozen for its logged revision, and any other meal the legacy
  /// ingredient math. A catalog meal used to take the legacy branch, which reads the
  /// ingredientless `recipes` row it lands on and so exported zeros.
  func syncLoggedMeal(
    historyId: Int64,
    recipeId: Int64,
    mealTitle: String,
    servingsConsumed: Int,
    portionMultiplier: Double = 1.0,
    swaps: [IngredientSwap] = [],
    loggedAt: Date = Date()
  ) async {
    guard appleHealthService.authorizationStatus() == .authorized else { return }

    do {
      let macros: RecipeMacros
      if let snapshot = try recipeRepository.catalogNutrition(forHistoryID: historyId) {
        // The snapshot has no sugar field, so sugar is 0 and the HealthKit writer skips it.
        macros = RecipeRepository.catalogMacros(from: snapshot)
      } else {
        macros = try nutritionService.macros(for: recipeId, swaps: swaps)
      }
      let scale = Double(max(1, servingsConsumed)) * portionMultiplier
      let record = AppleHealthMealRecord(
        syncIdentifier: "samgu.FridgeLuck.cooking_history.\(historyId)",
        syncVersion: 1,
        externalUUID: "samgu.FridgeLuck.cooking_history.\(historyId)",
        foodType: mealTitle,
        date: loggedAt,
        calories: macros.caloriesPerServing * scale,
        proteinGrams: macros.proteinPerServing * scale,
        carbsGrams: macros.carbsPerServing * scale,
        fatGrams: macros.fatPerServing * scale,
        fiberGrams: macros.fiberPerServing * scale,
        sugarGrams: macros.sugarPerServing * scale,
        sodiumMilligrams: macros.sodiumPerServing * scale
      )

      try await appleHealthService.writeMeal(record)
    } catch {
      mealLogSyncLogger.error(
        "Apple Health sync failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
