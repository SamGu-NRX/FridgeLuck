import Foundation
#if canImport(os)
  import os
#endif

#if canImport(os)
  private let mealLogSyncLogger = Logger(subsystem: "samgu.FridgeLuck", category: "MealLogSync")

  private func logSyncError(_ message: String) {
    mealLogSyncLogger.error("\(message, privacy: .public)")
  }
#else
  // Portable check harness: the fake Health service records calls, so failures surface
  // in assertions instead of the unified log.
  private func logSyncError(_ message: String) {}
#endif

/// Keeps Apple Health in step with the locally authoritative cooking journal: the local
/// database is the source of truth, sync is best-effort, and errors are logged, never
/// thrown back into UI flows.
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
    portionMultiplier: Double = 1.0,
    swaps: [IngredientSwap] = [],
    loggedAt: Date = Date()
  ) async {
    guard appleHealthService.authorizationStatus() == .authorized else { return }

    do {
      let macros = try nutritionService.macros(for: recipeId, swaps: swaps)
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
      logSyncError("Apple Health sync failed: \(error.localizedDescription)")
    }
  }

  /// Applies an accepted correction as delete-then-write under the SAME sync identifier,
  /// with the sync version set to the accepted revision — Health keeps only the latest
  /// accepted state, and corrected meals report their corrected macros and date.
  func syncCorrectedMeal(
    historyId: Int64,
    mealTitle: String,
    correctedPlan: MealConsumptionPlan,
    acceptedRevision: Int,
    recordedAt: Date
  ) async {
    guard appleHealthService.authorizationStatus() == .authorized else { return }
    let identifier = "samgu.FridgeLuck.cooking_history.\(historyId)"

    do {
      try await appleHealthService.deleteMeal(withSyncIdentifier: identifier)
      let macros = correctedPlan.totalMacros
      try await appleHealthService.writeMeal(
        AppleHealthMealRecord(
          syncIdentifier: identifier,
          syncVersion: acceptedRevision,
          externalUUID: identifier,
          foodType: mealTitle,
          date: recordedAt,
          calories: macros.calories,
          proteinGrams: macros.protein,
          carbsGrams: macros.carbs,
          fatGrams: macros.fat,
          fiberGrams: macros.fiber,
          sugarGrams: macros.sugar,
          sodiumMilligrams: macros.sodium
        ))
    } catch {
      // Local state is already corrected and stays authoritative; Health catches up on
      // the next correction or full re-log.
      logSyncError("Apple Health correction sync failed: \(error.localizedDescription)")
    }
  }

  /// Removes a deleted meal from Health. Nothing-found is tolerated; the local
  /// deletion is never rolled back on a Health failure.
  func removeLoggedMeal(historyId: Int64) async {
    guard appleHealthService.authorizationStatus() == .authorized else { return }
    do {
      try await appleHealthService.deleteMeal(
        withSyncIdentifier: "samgu.FridgeLuck.cooking_history.\(historyId)")
    } catch {
      logSyncError("Apple Health meal deletion failed: \(error.localizedDescription)")
    }
  }
}
