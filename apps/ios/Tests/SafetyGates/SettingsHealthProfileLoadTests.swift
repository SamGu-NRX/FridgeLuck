import GRDB
import XCTest

@testable import FridgeLuck

/// Settings screens save the whole health_profile row. They used to load with
/// `(try? fetchHealthProfile()) ?? .default`, so after a failed read a Save wrote the
/// default's empty allergen and diet lists over the household's stored ones.
final class SettingsHealthProfileLoadTests: XCTestCase {
  private struct ReadFailure: Error {}

  func testSaveAfterAFailedReadLeavesStoredAllergensUnchanged() throws {
    let repository = try makeRepository()
    try repository.saveHealthProfile(storedHousehold)

    let load = SettingsHealthProfileLoad.read { throw ReadFailure() }
    XCTAssertTrue(load.isFailed)
    XCTAssertNil(load.profile, "a failed read must not hand the screen a profile to edit")

    XCTAssertThrowsError(
      try load.save({ $0.displayName = "Sam" }, writing: repository.saveHealthProfile)
    ) { error in
      guard case SettingsHealthProfileLoad.SaveError.notLoaded = error else {
        return XCTFail("expected notLoaded, got \(error)")
      }
    }

    let after = try repository.fetchHealthProfile()
    XCTAssertEqual(after.allergenIngredientIds, storedHousehold.allergenIngredientIds)
    XCTAssertEqual(after.dietaryRestrictions, storedHousehold.dietaryRestrictions)
    XCTAssertEqual(after.displayName, storedHousehold.displayName)
  }

  func testSaveBeforeTheReadFinishesWritesNothing() throws {
    let repository = try makeRepository()
    try repository.saveHealthProfile(storedHousehold)

    XCTAssertThrowsError(
      try SettingsHealthProfileLoad.loading.save(
        { $0.allergenIngredientIds = "[]" }, writing: repository.saveHealthProfile))

    XCTAssertEqual(
      try repository.fetchHealthProfile().allergenIngredientIds,
      storedHousehold.allergenIngredientIds)
  }

  func testSaveAfterASuccessfulReadKeepsFieldsTheScreenDidNotEdit() throws {
    let repository = try makeRepository()
    try repository.saveHealthProfile(storedHousehold)

    let load = SettingsHealthProfileLoad.read { try repository.fetchHealthProfile() }
    try load.save({ $0.displayName = "Sam" }, writing: repository.saveHealthProfile)

    let after = try repository.fetchHealthProfile()
    XCTAssertEqual(after.displayName, "Sam")
    XCTAssertEqual(after.allergenIngredientIds, storedHousehold.allergenIngredientIds)
    XCTAssertEqual(after.dietaryRestrictions, storedHousehold.dietaryRestrictions)
  }

  private var storedHousehold: HealthProfile {
    var profile = HealthProfile.default
    profile.displayName = "Household"
    profile.allergenIngredientIds = "[12,38]"
    profile.dietaryRestrictions = "[\"vegetarian\"]"
    return profile
  }

  private func makeRepository() throws -> UserDataRepository {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return UserDataRepository(db: db)
  }
}
