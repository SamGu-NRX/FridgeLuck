import Foundation
import GRDB
@testable import FridgeLuck

/// In-memory fake for the Apple Health port: records keyed by sync identifier with
/// versions, a deletion log, and an injectable failure point — enough to assert what
/// real HealthKit calls would do without a device.
final class FakeAppleHealthServicing: AppleHealthServicing, @unchecked Sendable {
  enum CallKind: Equatable {
    case write(String)  // sync identifier
    case delete(String)  // sync identifier
  }

  /// Persisted meals keyed by their full sync identifier (later writes replace earlier
  /// ones with the same identifier, mirroring metadata-predicate deletion semantics).
  private(set) var records: [String: AppleHealthMealRecord] = [:]
  /// Ordered call log for idempotency and ordering assertions.
  private(set) var calls: [CallKind] = []
  /// When set, the NEXT matching call throws once and clears itself — one failure, then
  /// recovery, so tests can script a failing sync followed by a successful catch-up.
  var writeError: Error?
  var deleteError: Error?
  var isAuthorized = true

  private func takeError(_ error: Error?) -> Error? {
    guard let error else { return nil }
    writeError = nil
    deleteError = nil
    return error
  }

  func authorizationStatus() -> PermissionStatus {
    isAuthorized ? .authorized : .denied
  }

  func authorizationRequestStatus() async -> AppleHealthAuthorizationRequestStatus {
    isAuthorized ? .unnecessary : .unknown
  }

  func writeMeal(_ record: AppleHealthMealRecord) async throws {
    if let error = takeError(writeError) { throw error }
    calls.append(.write(record.syncIdentifier))
    records[record.syncIdentifier] = record
  }

  func deleteMeal(withSyncIdentifier syncIdentifier: String) async throws {
    if let error = takeError(deleteError) { throw error }
    calls.append(.delete(syncIdentifier))
    records.removeValue(forKey: syncIdentifier)
  }

  func fetchNutritionTotals(in interval: DateInterval) async throws -> AppleHealthNutritionTotals? {
    nil
  }

  func fetchDailyNutritionTotals(lastDays: Int, endingOn endDate: Date) async throws
    -> [AppleHealthNutritionDay]
  {
    []
  }

  /// The meal record written under the cooking-history identifier for a history id.
  func meal(forHistoryId historyId: Int64) -> AppleHealthMealRecord? {
    records["samgu.FridgeLuck.cooking_history.\(historyId)"]
  }

  func writeCallCount(forHistoryId historyId: Int64) -> Int {
    calls.filter { $0 == .write("samgu.FridgeLuck.cooking_history.\(historyId)") }.count
  }

  func deleteCallCount(forHistoryId historyId: Int64) -> Int {
    calls.filter { $0 == .delete("samgu.FridgeLuck.cooking_history.\(historyId)") }.count
  }
}

/// Plan fixture for sync tests: a real built plan (150 g rice, 50 g egg, 10 g scallion
/// at one serving) plus an edited variant, exactly as the correction flow passes them.
enum HealthSyncProbe {
  static func buildPlan(db: DatabaseQueue, servings: Int = 1, portion: Double = 1.0) throws
    -> MealConsumptionPlan
  {
    try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: servings, portionMultiplier: portion)
  }

  /// The same plan with the rice line edited to 137.5 g by the user.
  static func correctedPlan(from plan: MealConsumptionPlan) -> MealConsumptionPlan {
    var corrected = plan
    corrected.lines[0].plannedGrams = 137.5
    corrected.lines[0].provenance = .userVerified
    return corrected
  }
}
