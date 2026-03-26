import Foundation
import os

private let mealLogSyncLogger = Logger(subsystem: "samgu.FridgeLuck", category: "MealLogSync")

@MainActor
final class MealLogSyncCoordinator {
  private let appleHealthService: AppleHealthServicing
  private let nutritionService: NutritionService

  init(
    appleHealthService: AppleHealthServicing,
    nutritionService: NutritionService
  ) {
    self.appleHealthService = appleHealthService
    self.nutritionService = nutritionService
  }

  func syncLoggedMeal(
    historyId: Int64,
    recipeId: Int64,
    mealTitle: String,
    servingsConsumed: Int,
    loggedAt: Date = Date()
  ) async {
    guard appleHealthService.authorizationStatus() == .authorized else { return }

    do {
      let macros = try nutritionService.macros(for: recipeId)
      let scale = Double(max(1, servingsConsumed))
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
