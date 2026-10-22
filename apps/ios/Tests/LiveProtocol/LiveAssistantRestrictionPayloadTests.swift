import GRDB
import XCTest

@testable import FridgeLuck

@MainActor
final class LiveAssistantRestrictionPayloadTests: XCTestCase {
  func testSnapshotCarriesHouseholdRestrictions() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try await AppDatabase(dbQueue: db).warmBundledContentIfNeeded()
    let ingredients = try await db.read { try Ingredient.fetchAll($0) }
    let peanutGroup = try XCTUnwrap(AllergenSupport.groups.first { $0.id == "peanut" })
    let peanutID = try XCTUnwrap(AllergenSupport.matchingIDs(for: peanutGroup, in: ingredients).first)
    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[\(peanutID)]"
    profile.dietaryRestrictions = "[\"vegan\"]"
    try UserDataRepository(db: db).saveHealthProfile(profile)
    let restrictions = try SubstitutionService(db: db).liveSessionRestrictions()
    XCTAssertEqual(restrictions, ["peanut", "vegan"])
    let cook = CookModeViewModel(
      recipe: Recipe(
        id: 1, title: "Noodles", timeMinutes: 10, servings: 2, instructions: "1. Cook",
        tags: 0, source: .bundled, createdAt: nil),
      logsMeal: false,
      dependencies: .ephemeral())
    let payload = LiveAssistantViewModel.boundedSnapshot(
      from: cook, restrictions: restrictions)
    let cookSession = payload["cookSession"] as? [String: Any]
    let eaters = cookSession?["eaters"] as? [[String: Any]]
    XCTAssertEqual(eaters?.count, 1)
    XCTAssertEqual(eaters?.first?["restrictions"] as? [String], ["peanut", "vegan"])
  }

  func testCorruptProfilePreventsLiveSessionStartup() async throws {
    for column in ["allergen_ingredient_ids", "dietary_restrictions"] {
      let db = try DatabaseQueue()
      try DatabaseMigrations.migrate(db)
      try UserDataRepository(db: db).saveHealthProfile(.default)
      try await db.write { db in
        try db.execute(sql: "UPDATE health_profile SET \(column) = 'not-json' WHERE id = 1")
        XCTAssertEqual(db.changesCount, 1)
      }
      let live = LiveAssistantViewModel(
        recipeContext: LiveAssistantRecipeContext(
          recipeID: 1, title: "Noodles", timeMinutes: 10, servings: 2,
          instructions: "1. Cook", ingredients: []))

      XCTAssertFalse(live.installHouseholdRecheck(from: SubstitutionService(db: db)))
      await live.start()
      guard case .failed(let message) = live.connectionState else {
        live.stop()
        return XCTFail("A corrupt \(column) must prevent startup")
      }
      XCTAssertTrue(message.contains("household restrictions"))
      XCTAssertFalse(live.isConnected)
      live.stop()
    }
  }
}
