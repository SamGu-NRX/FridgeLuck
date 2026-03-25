import FLFeatureLogic
import Foundation

struct AppleHealthMealRecord: Sendable {
  let date: Date
  let calories: Double
  let proteinGrams: Double
  let carbsGrams: Double
  let fatGrams: Double
  let fiberGrams: Double
  let sugarGrams: Double
  let sodiumMilligrams: Double
}

struct AppleHealthNutritionTotals: Sendable {
  let calories: Double
  let proteinGrams: Double
  let carbsGrams: Double
  let fatGrams: Double
  let fiberGrams: Double
  let sugarGrams: Double
  let sodiumMilligrams: Double
}

protocol AppleHealthServicing: Sendable {
  func authorizationStatus() -> PermissionStatus
  @MainActor
  func requestAuthorization() async -> PermissionRequestResult
  func writeMeal(_ record: AppleHealthMealRecord) async throws
  func fetchTodayNutritionTotals() async throws -> AppleHealthNutritionTotals?
}
