import FLFeatureLogic
import Foundation

enum AppleHealthAuthorizationRequestStatus: Sendable {
  case shouldRequest
  case unnecessary
  case unknown
  case failed(String)
  case unavailable
}

struct AppleHealthMealRecord: Sendable {
  let syncIdentifier: String
  let syncVersion: Int
  let externalUUID: String
  let foodType: String
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

struct AppleHealthNutritionDay: Sendable {
  let date: Date
  let totals: AppleHealthNutritionTotals
}

protocol AppleHealthServicing: Sendable {
  func authorizationStatus() -> PermissionStatus
  func authorizationRequestStatus() async -> AppleHealthAuthorizationRequestStatus
  func writeMeal(_ record: AppleHealthMealRecord) async throws
  func fetchNutritionTotals(in interval: DateInterval) async throws -> AppleHealthNutritionTotals?
  func fetchDailyNutritionTotals(lastDays: Int, endingOn endDate: Date) async throws
    -> [AppleHealthNutritionDay]
}
