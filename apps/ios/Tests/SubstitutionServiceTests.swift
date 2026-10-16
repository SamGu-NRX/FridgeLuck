import GRDB
import XCTest

@testable import FridgeLuck

/// Service-level behavior over the shipped bundle: offers must survive the real
/// launch order (the service is built before hydration) and the cook-flow
/// allergen recheck must screen the household's explicit exclusions and fail
/// closed on a read error. Tests run hosted in the app (TEST_HOST), so
/// Bundle.main carries the shipped substitutions-v2.json, recipes-v2.json, and
/// USDA catalog — the same resources the running app reads.
final class SubstitutionServiceTests: XCTestCase {
  private func makeMigratedDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return db
  }

  // MARK: - Bridge timing (Codex r4289584058)

  /// AppDependencies builds `SubstitutionService` before
  /// `warmBundledContentIfNeeded()` hydrates the catalog and rebuilds the
  /// identity bridge, so the service must observe the bridge at query time
  /// rather than snapshot it during init.
  func testOffersAppearAfterCatalogHydrationEvenWhenBuiltBeforeIt() async throws {
    let db = try makeMigratedDatabase()
    let service = SubstitutionService(db: db)  // built before hydration, like launch

    try await AppDatabase(dbQueue: db).warmBundledContentIfNeeded()

    let table = try XCTUnwrap(service.substitutionTable, "the shipped substitutions-v2.json must decode")
    let originalKeys = Set(table.originalKeys)
    let bridged = try await db.read { db -> [Int64: Set<String>] in
      var keysByAppID: [Int64: Set<String>] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT ingredient_key, ingredient_id FROM recipes_catalog_ingredient_bridge")
      {
        guard let key: String = row["ingredient_key"], let id: Int64 = row["ingredient_id"]
        else { continue }
        keysByAppID[id, default: []].insert(key)
      }
      return keysByAppID
    }
    let candidates = bridged.filter { !$0.value.isDisjoint(with: originalKeys) }.map(\.key).sorted()
    XCTAssertFalse(
      candidates.isEmpty,
      "the hydrated bundle must bridge at least one table original key into the app ingredient space")

    XCTAssertTrue(
      candidates.contains { !service.substitutions(for: $0).isEmpty },
      "after hydration the service must offer swaps for a bridged ingredient — maps snapshotted at init stay empty and yield none"
    )
  }

  // MARK: - Household exclusions (Codex r4289584073)

  /// A household that flagged an ingredient allergen but set no diet must still
  /// have that ingredient block its substitute: the recheck screens the union
  /// of explicit allergen ids and diet exclusions, independent of the diet.
  func testExplicitAllergenBlocksTheSubstituteEvenWithoutADiet() throws {
    let db = try makeMigratedDatabase()
    let service = SubstitutionService(db: db)
    let userData = UserDataRepository(db: db)
    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[42]"
    profile.dietaryRestrictions = "[]"
    try userData.saveHealthProfile(profile)

    XCTAssertEqual(
      service.substituteIsAllergen(for: 42), true,
      "an explicit household allergen blocks its substitute with no diet set")
    XCTAssertEqual(
      service.substituteIsAllergen(for: 43), false,
      "an unflagged substitute stays allowed when no diet is active")
  }

  /// Diet-excluded ingredient ids (the vegan dairy set here) block their
  /// substitutes outright, without depending on bridge resolution or a
  /// composition lookup.
  func testDietExcludedIngredientIDsBlockTheirSubstitutes() throws {
    let db = try makeMigratedDatabase()
    let service = SubstitutionService(db: db)
    let userData = UserDataRepository(db: db)
    var profile = HealthProfile.default
    profile.dietaryRestrictions = "[\"vegan\"]"
    try userData.saveHealthProfile(profile)

    XCTAssertEqual(
      service.substituteIsAllergen(for: 12), true,
      "a diet-excluded ingredient id blocks its substitute")
  }

  // MARK: - Fail-closed read (Codex r4289584068)

  /// A failed health-profile read must not read as "no restrictions": callers
  /// treat `nil` as blocked, so the recheck fails closed.
  func testHealthProfileReadFailureBlocksTheSubstitute() throws {
    let db = try makeMigratedDatabase()
    try db.write { db in
      try db.execute(sql: "DROP TABLE health_profile")
    }
    let service = SubstitutionService(db: db)

    XCTAssertNil(
      service.substituteIsAllergen(for: 1),
      "a failed profile read must block the swap, not allow it")
  }
}
