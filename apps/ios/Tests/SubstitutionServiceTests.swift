import FLFeatureLogic
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

  // MARK: - Receipt recheck (receipt.schema.json's allergenRecheck)

  /// The live chat installs `substitutionRecheck` as its swap screen. An explicit
  /// household allergen refuses with a named blocked path; with no restriction at
  /// all, an unbridged substitute stays allowed, as the offer screen allows it.
  func testRecheckRefusesAnExplicitAllergenAndAllowsAnUnrestrictedHousehold() throws {
    let db = try makeMigratedDatabase()
    let service = SubstitutionService(db: db)
    let userData = UserDataRepository(db: db)

    let unrestricted = service.substitutionRecheck(for: 1, substituteId: 43, eaters: [])
    XCTAssertEqual(unrestricted, .verified(eaters: ["household"]))

    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[42]"
    try userData.saveHealthProfile(profile)
    let flagged = service.substitutionRecheck(for: 1, substituteId: 42, eaters: ["Ana"])
    XCTAssertEqual(flagged.verdict, .unsupported)
    XCTAssertEqual(flagged.eaters, ["Ana"])
    XCTAssertTrue(
      flagged.blockedPath?.hasPrefix("Contains a household-excluded ingredient via ") == true,
      "blocked path: \(flagged.blockedPath ?? "nil")")
    XCTAssertFalse(flagged.allowsSwap)
  }

  func testRecheckFailsClosedWhenTheProfileCannotBeRead() throws {
    let db = try makeMigratedDatabase()
    try db.write { db in
      try db.execute(sql: "DROP TABLE health_profile")
    }
    let service = SubstitutionService(db: db)

    let recheck = service.substitutionRecheck(for: 1, substituteId: 2, eaters: [])
    XCTAssertEqual(recheck.verdict, .unknown)
    XCTAssertFalse(recheck.allowsSwap, "an unread profile must refuse the swap")
  }

  /// Over the shipped bundle, a vegan household: a known dairy substitute refuses with
  /// the diet named, and every swap the service offers passes the recheck, so the live
  /// chat never offers a swap it then refuses, nor executes one the offer screen dropped.
  func testRecheckAgreesWithTheOfferScreenOverTheShippedBundle() async throws {
    let db = try makeMigratedDatabase()
    try await AppDatabase(dbQueue: db).warmBundledContentIfNeeded()
    let service = SubstitutionService(db: db)
    var profile = HealthProfile.default
    profile.dietaryRestrictions = "[\"vegan\"]"
    try UserDataRepository(db: db).saveHealthProfile(profile)

    // A bridged id whose every key has known classes and one of them is dairy, outside
    // the vegan diet's explicit id list (that path names the exclusion instead).
    let dairyID = try await db.read { db in
      try Int64.fetchOne(
        db,
        sql: """
          SELECT b.ingredient_id
          FROM recipes_catalog_ingredient_bridge b
          LEFT JOIN recipes_catalog_ingredients v ON v.key = b.ingredient_key
          WHERE b.ingredient_id IS NOT NULL AND b.ingredient_id NOT IN (12, 13, 14, 32, 50)
          GROUP BY b.ingredient_id
          HAVING MAX(v.classes LIKE '%"dairy"%') = 1
             AND MAX(v.classes IS NULL OR v.classes = '[]' OR v.classes LIKE '%"unknown"%') = 0
          ORDER BY b.ingredient_id
          LIMIT 1
          """)
    }
    let dairy = try XCTUnwrap(dairyID, "the shipped bundle bridges a dairy ingredient")
    let refused = service.substitutionRecheck(for: 1, substituteId: dairy, eaters: [])
    XCTAssertEqual(refused.verdict, .unsupported)
    XCTAssertTrue(
      refused.blockedPath?.hasPrefix("Conflicts with the vegan diet via ") == true,
      "blocked path: \(refused.blockedPath ?? "nil")")

    let originals = try await Self.bridgedTableOriginals(db, service: service)
    var checked = 0
    for original in originals {
      for swap in service.substitutions(for: original) {
        let recheck = service.substitutionRecheck(
          for: original, substituteId: swap.substituteId, eaters: [])
        XCTAssertTrue(
          recheck.allowsSwap,
          "offered \(original) -> \(swap.substituteId) but the recheck refused: \(recheck.canonicalJSON)")
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 0, "a vegan household is offered at least one reviewed swap")
  }

  /// App ingredient ids whose bridged key is an original in the shipped reviewed table,
  /// ascending: the ids a swap can start from.
  private static func bridgedTableOriginals(
    _ db: DatabaseQueue, service: SubstitutionService
  ) async throws -> [Int64] {
    let originalKeys = Set(try XCTUnwrap(service.substitutionTable).originalKeys)
    let rows = try await db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT ingredient_key, ingredient_id FROM recipes_catalog_ingredient_bridge
          WHERE ingredient_id IS NOT NULL
          """
      ).map { (key: $0["ingredient_key"] as String, id: $0["ingredient_id"] as Int64) }
    }
    return Set(rows.filter { originalKeys.contains($0.key) }.map(\.id)).sorted()
  }
}
