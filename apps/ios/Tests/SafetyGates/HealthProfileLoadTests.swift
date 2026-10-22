import GRDB
import XCTest

@testable import FridgeLuck

/// Settings screens and onboarding save the whole health_profile row. After a failed read,
/// Settings saved `HealthProfile.default` and onboarding saved its steps' defaults, so both
/// wrote empty allergen and diet lists over the household's stored ones.
final class HealthProfileLoadTests: XCTestCase {
  private struct ReadFailure: Error {}

  func testSaveAfterAFailedReadLeavesStoredAllergensUnchanged() throws {
    let repository = try makeRepository()
    try repository.saveHealthProfile(storedHousehold)

    let load = HealthProfileLoad.read { throw ReadFailure() }
    XCTAssertTrue(load.isFailed)
    XCTAssertNil(load.profile, "a failed read must not hand the screen a profile to edit")

    XCTAssertThrowsError(
      try load.save({ $0.displayName = "Sam" }, writing: repository.saveHealthProfile)
    ) { error in
      guard case HealthProfileLoad.SaveError.notLoaded = error else {
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
      try HealthProfileLoad.loading.save(
        { $0.allergenIngredientIds = "[]" }, writing: repository.saveHealthProfile))

    XCTAssertEqual(
      try repository.fetchHealthProfile().allergenIngredientIds,
      storedHousehold.allergenIngredientIds)
  }

  func testSaveAfterASuccessfulReadKeepsFieldsTheScreenDidNotEdit() throws {
    let repository = try makeRepository()
    try repository.saveHealthProfile(storedHousehold)

    let load = HealthProfileLoad.read { try repository.fetchHealthProfile() }
    try load.save({ $0.displayName = "Sam" }, writing: repository.saveHealthProfile)

    let after = try repository.fetchHealthProfile()
    XCTAssertEqual(after.displayName, "Sam")
    XCTAssertEqual(after.allergenIngredientIds, storedHousehold.allergenIngredientIds)
    XCTAssertEqual(after.dietaryRestrictions, storedHousehold.dietaryRestrictions)
  }

  /// The existing household reopens onboarding, the profile read fails, the user dismisses
  /// the alert and finishes setup with the steps still showing defaults.
  func testOnboardingCompletionAfterAFailedReadLeavesStoredAllergensUnchanged() throws {
    let repository = try makeRepository()
    try repository.saveHealthProfile(storedHousehold)

    let load = HealthProfileLoad.read { throw ReadFailure() }
    XCTAssertThrowsError(
      try defaultOnboardingChoices.complete(over: load, writing: repository.saveHealthProfile))

    let after = try repository.fetchHealthProfile()
    XCTAssertEqual(after.allergenIngredientIds, storedHousehold.allergenIngredientIds)
    XCTAssertEqual(after.dietaryRestrictions, storedHousehold.dietaryRestrictions)
  }

  /// A fresh install has no row. That read succeeds with the default, so onboarding still
  /// creates the first profile.
  func testOnboardingCompletionOnAFreshInstallCreatesTheProfile() throws {
    let repository = try makeRepository()
    let load = HealthProfileLoad.read { try repository.fetchHealthProfile() }
    XCTAssertNotNil(load.profile)

    let choices = OnboardingProfileChoices(
      displayName: "Sam", age: 30, goal: .general, dailyCalories: 2000,
      dietID: "vegan", allergenIDs: [38, 12])
    try choices.complete(over: load, writing: repository.saveHealthProfile)

    let after = try repository.fetchHealthProfile()
    XCTAssertEqual(after.displayName, "Sam")
    XCTAssertEqual(after.dietaryRestrictions, "[\"vegan\"]")
    XCTAssertEqual(after.allergenIngredientIds, "[12,38]")
  }

  private var defaultOnboardingChoices: OnboardingProfileChoices {
    OnboardingProfileChoices(
      displayName: "Household", age: 25, goal: .general,
      dailyCalories: HealthGoal.general.suggestedCalories, dietID: "classic", allergenIDs: [])
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
