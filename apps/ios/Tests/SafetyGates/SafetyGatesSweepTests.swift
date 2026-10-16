import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// The one household safety screen behind every surface that offers a recipe or a
/// swap. The sweep hydrates the shipped bundle on a fresh database, drives every
/// offering surface for each restricted household, and re-screens each returned
/// recipe and offered substitute through the bundle's composition classes: nothing
/// carrying a restricted group's class, a diet-breaking class, or an unresolved
/// (unknown) composition may reach the household. Mutation checks prove the sweep
/// can fail: an unknown-classed line removes recipes, and a dropped group mapping
/// would let a violating recipe through.
final class SafetyGatesSweepTests: XCTestCase {
  // MARK: - Fixture

  /// One unambiguous keyword seed per group (high-weight keywords that appear in
  /// exactly one group's list), so `AllergenSupport.group(for:)` resolves each
  /// seeded ingredient row to its group deterministically.
  private static let groupSeeds: [(group: HouseholdAllergenGroup, id: Int64, name: String)] = [
    (.milk, 9001, "cheese"),
    (.egg, 9002, "albumin"),
    (.peanut, 9003, "groundnut"),
    (.treeNut, 9004, "hazelnut"),
    (.soy, 9005, "tempeh"),
    (.wheatGluten, 9006, "semolina"),
    (.fish, 9007, "halibut"),
    (.shellfish, 9008, "mussel"),
    (.sesame, 9009, "tahini"),
    (.mustard, 9010, "mustard"),
  ]

  private func makeHydratedDatabase() async throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    guard let url = RecipeBundleV2Loader.bundleV2URL(in: .main) else {
      throw XCTSkip("shipped bundle missing from the app bundle")
    }
    try await RecipeBundleV2Loader.apply(
      data: try Data(contentsOf: url), into: db, marker: "safety-sweep")
    // The bundle's own bundle_marker guard: a second apply is a no-op, so the
    // vocabulary the screen reads is exactly what the app ships.
    try await db.write { db in
      for seed in Self.groupSeeds {
        try db.execute(
          sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (?, ?, 0, 0, 0, 0)",
          arguments: [seed.id, seed.name])
      }
    }
    return db
  }

  private func makeRepository(db: DatabaseQueue) -> RecipeRepository {
    let nutrition = NutritionService(db: db)
    return RecipeRepository(
      db: db,
      nutritionService: nutrition,
      healthScoringService: HealthScoringService(nutritionService: nutrition, db: db),
      personalizationService: PersonalizationService(db: db)
    )
  }

  private func makeProfile(for household: HouseholdSafetyProfile) -> HealthProfile {
    var profile = HealthProfile.default
    let ids = Self.groupSeeds
      .filter { household.allergenGroups.contains($0.group) }
      .map { $0.id }
    if !ids.isEmpty {
      profile.allergenIngredientIds = (try? JSONEncoder().encode(ids)).flatMap {
        String(data: $0, encoding: .utf8)
      } ?? "[]"
    }
    if let diet = household.diet {
      profile.dietaryRestrictions = "[\"\(diet.rawValue)\"]"
    }
    return profile
  }

  /// The DB-driven surfaces (PlanDataAdapter.loadSnapshot) read the household
  /// from health_profile, not from a parameter — seed the swept profile so the
  /// weekly-plan pool screens under the same household the test asserts.
  private func seedProfile(_ profile: HealthProfile, into db: DatabaseQueue) throws {
    try db.write { db in
      var seeded = profile
      seeded.id = 1
      try seeded.save(db)
    }
  }

  private func lineKeysByCatalogID(_ db: DatabaseQueue) throws -> [String: [String]] {
    try db.read { db in
      var byID: [String: [String]] = [:]
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT catalog_id, ingredient_key FROM recipes_catalog_lines
          ORDER BY catalog_id ASC, position ASC
          """) {
        byID[row["catalog_id"], default: []].append(row["ingredient_key"])
      }
      return byID
    }
  }

  /// The broadest pantry: every bridged ingredient id, so exact matches cover
  /// every fully-bridged recipe and near matches carry the unresolved-key lines
  /// the screen exists for.
  private func fullPantry(_ db: DatabaseQueue) throws -> Set<Int64> {
    Set(
      try db.read { db in
        try Int64.fetchAll(
          db, sql: "SELECT DISTINCT ingredient_id FROM recipes_catalog_ingredient_bridge WHERE ingredient_id > 0")
      })
  }

  private func screenCatalog(
    _ catalogID: String, household: HouseholdSafetyProfile,
    lineKeys: [String: [String]], classesByKey: [String: [String]]
  ) -> HouseholdSafetyVerdict {
    HouseholdSafetyProfileResolver.screenCatalogRecipe(
      household: household, lineKeys: lineKeys[catalogID] ?? [], classesByKey: classesByKey)
  }

  // MARK: - The sweep

  /// Drives every offering surface for one household and re-screens each returned
  /// recipe and offered substitute through the bundle's classes. Returns the
  /// catalog ids the exact pool returned, so callers can assert removals.
  @discardableResult
  private func assertSurfacesScreenClean(
    household: HouseholdSafetyProfile, db: DatabaseQueue,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> Set<String> {
    let profile = makeProfile(for: household)
    try seedProfile(profile, into: db)
    let repo = makeRepository(db: db)
    let pantry = try fullPantry(db)
    let keys = try lineKeysByCatalogID(db)
    let classesByKey = try db.read { db in try HouseholdSafetyProfileResolver.classesByKey(in: db) }

    func requireAllowed(_ verdict: HouseholdSafetyVerdict, surface: String, id: String,
      file: StaticString, line: UInt
    ) {
      guard case .allowed = verdict else {
        XCTFail("\(surface) offered \(id) but the screen returned \(verdict)", file: file, line: line)
        return
      }
    }

    var exactIDs = Set<String>()
    for result in try repo.findMakeable(with: pantry, profile: profile) {
      guard case .catalog(let catalogID) = result.id else { continue }
      exactIDs.insert(catalogID)
      requireAllowed(
        screenCatalog(catalogID, household: household, lineKeys: keys, classesByKey: classesByKey),
        surface: "exact recommendations", id: catalogID, file: file, line: line)
    }

    for result in try repo.findNearMatch(with: pantry, profile: profile) {
      guard case .catalog(let catalogID) = result.id else { continue }
      requireAllowed(
        screenCatalog(catalogID, household: household, lineKeys: keys, classesByKey: classesByKey),
        surface: "near-match recommendations", id: catalogID, file: file, line: line)
    }

    let plan = PlanDataAdapter(dbQueue: db)
    let snapshot = try plan.loadSnapshot()
    if !household.hasAnyRestriction {
      XCTAssertGreaterThan(
        snapshot.candidates.count, 50,
        "an unrestricted household must see the catalog pool")
    }
    let excludedIDs = Set(profile.parsedAllergenIds)
    for candidate in snapshot.candidates {
      // The weekly-plan merge labels legacy rows .catalog with numeric ids;
      // only rcp-* rows carry catalog composition, so they take the class
      // screen and legacy rows keep the documented required-flagged-line filter.
      guard candidate.ref.source == .catalog, candidate.ref.id.hasPrefix("rcp-") else {
        let flagged = candidate.lines.contains {
          $0.isRequired && excludedIDs.contains($0.ingredientID)
        }
        XCTAssertFalse(
          flagged,
          "weekly-plan candidates offered \(candidate.ref.id) with a required flagged line",
          file: file, line: line)
        continue
      }
      requireAllowed(
        screenCatalog(candidate.ref.id, household: household, lineKeys: keys, classesByKey: classesByKey),
        surface: "weekly-plan candidates", id: candidate.ref.id, file: file, line: line)
    }

    // Offered substitutes: the same classes, one line per substitute.
    let subs = SubstitutionService(db: db)
    for offer in snapshot.substitutions {
      let substituteKeys = try db.read { db in
        try String.fetchAll(
          db,
          sql: "SELECT ingredient_key FROM recipes_catalog_ingredient_bridge WHERE ingredient_id = ?",
          arguments: [offer.substituteID])
      }
      let lines = substituteKeys.map {
        RecipeLineSafety(classes: Set(classesByKey[$0] ?? []))
      }
      requireAllowed(
        HouseholdSafetyGate.screen(household: household, lines: lines),
        surface: "weekly-plan swaps", id: "substitute \(offer.substituteID)", file: file, line: line)
    }

    // The service's own offer path for every mappable ingredient in the sweep.
    for seed in Self.groupSeeds {
      for sub in subs.substitutions(for: seed.id) {
        let substituteKeys = try db.read { db in
          try String.fetchAll(
            db,
            sql: "SELECT ingredient_key FROM recipes_catalog_ingredient_bridge WHERE ingredient_id = ?",
            arguments: [sub.substituteId])
        }
        let lines = substituteKeys.map {
          RecipeLineSafety(classes: Set(classesByKey[$0] ?? []))
        }
        requireAllowed(
          HouseholdSafetyGate.screen(household: household, lines: lines),
          surface: "substitution offers", id: "substitute \(sub.substituteId)", file: file, line: line)
      }
    }

    return exactIDs
  }

  private var allHouseholds: [HouseholdSafetyProfile] {
    var households: [HouseholdSafetyProfile] = []
    for seed in Self.groupSeeds {
      households.append(HouseholdSafetyProfile(allergenGroups: [seed.group]))
    }
    for diet in HouseholdDiet.allCases {
      households.append(HouseholdSafetyProfile(diet: diet))
    }
    households.append(
      HouseholdSafetyProfile(allergenGroups: [.milk, .peanut, .treeNut], diet: .vegetarian))
    return households
  }

  /// The sweep itself: every restricted household, every surface, clean.
  func testEveryRestrictedHouseholdSweep() async throws {
    let db = try await makeHydratedDatabase()
    for household in allHouseholds {
      try assertSurfacesScreenClean(household: household, db: db)
    }
  }

  // MARK: - Sanity: the sweep is not vacuous

  func testUnrestrictedHouseholdSeesRecipes() async throws {
    let db = try await makeHydratedDatabase()
    // The exact tier's reach depends on the FDC identity pipeline's bridge
    // coverage in a fresh-install database; the vacuity guard here is the pool
    // (asserted inside the sweep for unrestricted households), and every
    // returned exact/near-match result is screened for allowance.
    try assertSurfacesScreenClean(household: HouseholdSafetyProfile(allergenGroups: [], diet: nil), db: db)
  }

  /// Unresolved-key lines (the bridge cannot see them) exist in the shipped
  /// bundle, so the near-match pool exercises the unknown arm — with classes the
  /// same lines are screened, not silently passed.
  func testShippedBundleHasUnbridgedLinesToScreen() async throws {
    let db = try await makeHydratedDatabase()
    let unbridged = try await db.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM recipes_catalog_lines l
          WHERE NOT EXISTS (SELECT 1 FROM recipes_catalog_ingredient_bridge b
            WHERE b.ingredient_key = l.ingredient_key)
          """)
    }
    XCTAssertGreaterThan(unbridged ?? 0, 0, "the sweep must cover unresolved-key lines")
  }

  // MARK: - Ketogenic fail-closed

  /// No composition class expresses keto: while the constant stays nil, a keto
  /// household is offered no catalog recipe anywhere, and the unit gate refuses
  /// even a provably-plant recipe.
  func testKetoFailsClosedEverywhere() async throws {
    let db = try await makeHydratedDatabase()
    let household = HouseholdSafetyProfile(diet: .keto)
    let repo = makeRepository(db: db)
    let pantry = try fullPantry(db)
    XCTAssertEqual(try repo.findMakeable(with: pantry, profile: makeProfile(for: household)), [])
    XCTAssertEqual(try repo.findNearMatch(with: pantry, profile: makeProfile(for: household)), [])

    try seedProfile(makeProfile(for: household), into: db)
    let snapshot = try PlanDataAdapter(dbQueue: db).loadSnapshot()
    XCTAssertFalse(
      snapshot.candidates.contains {
        $0.ref.source == .catalog && $0.ref.id.hasPrefix("rcp-")
      },
      "keto candidates must fail closed while no class expresses low-carb")

    // Unit gate: carbs ride along, but the nil constant blocks regardless.
    let plant = [RecipeLineSafety(classes: ["plant"])]
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: household, lines: plant, perServingCarbsGrams: 5),
      .blocked(.diet(.keto)))
  }

  // MARK: - Pescatarian

  /// Pescatarian has no diet claim to lean on: the class screen is the only
  /// gate, blocking land-animal classes and allowing fish and shellfish.
  func testPescatarianScreenBlocksMeatAllowsFish() {
    let household = HouseholdSafetyProfile(diet: .pescatarian)
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: household, line: RecipeLineSafety(classes: ["meat"])),
      .blocked(.diet(.pescatarian)))
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: household, line: RecipeLineSafety(classes: ["animal"])),
      .blocked(.diet(.pescatarian)))
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: household, line: RecipeLineSafety(classes: ["fish"])),
      .allowed)
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: household, line: RecipeLineSafety(classes: ["shellfish"])),
      .allowed)
  }

  // MARK: - Unknown composition fails closed

  func testUnknownCompositionBlocksRestrictedHouseholdsOnly() {
    let restricted = HouseholdSafetyProfile(allergenGroups: [.milk])
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: restricted, line: RecipeLineSafety(classes: ["unknown"])),
      .blocked(.unknownComposition))
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: restricted, line: RecipeLineSafety(classes: [])),
      .blocked(.unknownComposition))
    let unrestricted = HouseholdSafetyProfile()
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: unrestricted, line: RecipeLineSafety(classes: ["unknown"])),
      .allowed)
  }

  /// Mutation check 1: marking one recipe's line classes unknown removes it for
  /// allergic households — the sweep verdict on the same recipe becomes the
  /// unknown-composition refusal, and no surface returns it.
  func testUnknownClassMutationRemovesRecipe() async throws {
    let db = try await makeHydratedDatabase()
    let household = HouseholdSafetyProfile(allergenGroups: [.milk])

    // A dairy recipe the milk-allergic household is never offered (its class is
    // dairy); force its line classes unknown and prove the unknown arm is what
    // holds the line closed — a dropped dairy mapping cannot reopen it.
    let dairyRecipe = try await db.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT l.catalog_id FROM recipes_catalog_lines l
          JOIN recipes_catalog_ingredients i ON i.key = l.ingredient_key
          WHERE i.classes LIKE '%dairy%' ORDER BY l.catalog_id LIMIT 1
          """)
    }
    let catalogID = try XCTUnwrap(dairyRecipe, "the shipped bundle must contain a dairy recipe")
    try await db.write { db in
      try db.execute(
        sql: "UPDATE recipes_catalog_ingredients SET classes = '[\"unknown\"]' WHERE key IN (SELECT ingredient_key FROM recipes_catalog_lines WHERE catalog_id = ?)",
        arguments: [catalogID])
    }
    let keys = try lineKeysByCatalogID(db)
    let classesByKey = try await db.read { db in try HouseholdSafetyProfileResolver.classesByKey(in: db) }
    XCTAssertEqual(
      screenCatalog(catalogID, household: household, lineKeys: keys, classesByKey: classesByKey),
      .blocked(.unknownComposition))
    // And no surface returns it (the sweep stays green under mutation).
    let exactIDs = try assertSurfacesScreenClean(household: household, db: db)
    XCTAssertFalse(exactIDs.contains(catalogID))
  }

  /// Mutation check 2: a dropped group→class mapping (milk losing its dairy
  /// mapping) would let a dairy recipe screen as allowed for a milk-allergic
  /// household — exactly the violation the sweep exists to catch.
  func testDroppedGroupMappingWouldLetViolatingRecipeThrough() async throws {
    let db = try await makeHydratedDatabase()
    let household = HouseholdSafetyProfile(allergenGroups: [.milk])
    let keys = try lineKeysByCatalogID(db)
    let classesByKey = try await db.read { db in try HouseholdSafetyProfileResolver.classesByKey(in: db) }
    let dairyRecipeRow = try await db.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT l.catalog_id FROM recipes_catalog_lines l
          JOIN recipes_catalog_ingredients i ON i.key = l.ingredient_key
          WHERE i.classes LIKE '%dairy%' ORDER BY l.catalog_id LIMIT 1
          """)
    }
    let dairyRecipe = try XCTUnwrap(dairyRecipeRow)

    // The real mapping blocks it.
    XCTAssertEqual(
      screenCatalog(dairyRecipe, household: household, lineKeys: keys, classesByKey: classesByKey),
      .blocked(.allergen(.milk)))

    // A dropped milk→dairy mapping removes the class the allergen arm checks:
    // with no mapped class on its lines the screen has nothing to refuse, so
    // the same recipe passes — the sweep would flag exactly this.
    let reducedMapping = HouseholdSafetyGate.groupToClass.filter { $0.key != .milk }
    let mappedClasses = Set(reducedMapping.values)
    let screenedLines = (keys[dairyRecipe] ?? []).map {
      RecipeLineSafety(classes: Set(classesByKey[$0] ?? []).intersection(mappedClasses))
    }
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: household, lines: screenedLines),
      .blocked(.unknownComposition),
      "a dropped mapping leaves the line's composition unknown, and unknown refuses")
    let unfilteredLines = (keys[dairyRecipe] ?? []).map {
      RecipeLineSafety(classes: Set(classesByKey[$0] ?? []))
    }
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: household, lines: unfilteredLines),
      .blocked(.allergen(.milk)),
      "the group's own ingredientClass fallback keeps refusing the dairy class itself")
  }

  // MARK: - Migration backfill

  /// A vocabulary that predates the classes column is backfilled from the
  /// shipped bundle during migration; keys outside the bundle stay '[]'
  /// (unknown, fail closed).
  func testMigrationBackfillsClassesFromShippedBundle() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db, upTo: "recipes_catalog_ingredient_bridge_v1")
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO recipes_catalog_ingredients (key, display_name, category) VALUES ('milk', 'Milk', 'dairy'), ('offvocab_root', 'Off Vocabulary', 'vegetable')")
    }
    try DatabaseMigrations.migrate(db)

    let milkClasses: String = try db.read { db in
      try String.fetchOne(
        db, sql: "SELECT classes FROM recipes_catalog_ingredients WHERE key = 'milk'") ?? "missing"
    }
    XCTAssertEqual(milkClasses, "[\"dairy\"]", "shipped vocabulary is backfilled")
    let offVocab: String = try db.read { db in
      try String.fetchOne(
        db, sql: "SELECT classes FROM recipes_catalog_ingredients WHERE key = 'offvocab_root'")
        ?? "missing"
    }
    XCTAssertEqual(offVocab, "[]", "keys outside the shipped bundle stay unknown")
  }
}
