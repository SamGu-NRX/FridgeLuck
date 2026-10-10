import Foundation
import os

private let mealLogSyncLogger = Logger(subsystem: "samgu.FridgeLuck", category: "MealLogSync")

@MainActor
final class MealLogSyncCoordinator {
  private let appleHealthService: AppleHealthServicing
  private let nutritionSnapshotService: NutritionSnapshotService

  init(
    appleHealthService: AppleHealthServicing,
    nutritionSnapshotService: NutritionSnapshotService
  ) {
    self.appleHealthService = appleHealthService
    self.nutritionSnapshotService = nutritionSnapshotService
  }

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
      // Report the meal's frozen snapshot so catalog corrections after
      // logging cannot change what was written to Apple Health. The scale
      // arithmetic (per-serving × consumed × portion) is unchanged. A missing
      // snapshot skips the sync (logged) rather than writing values derived
      // from the mutable catalog.
      let macros = try nutritionSnapshotService.capturedMacros(historyId: historyId)
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
