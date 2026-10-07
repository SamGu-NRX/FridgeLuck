import GRDB
import XCTest

@testable import FridgeLuck

final class IngredientCatalogResolverTests: XCTestCase {
  private func makeResolver() throws -> IngredientCatalogResolver {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      let rows: [(Int64, String)] = [
        (168287, "Salt Pork (Raw, Cured)"),
        (169884, "Soy Vermicelli (Dry)"),
        (171301, "Kefir (Lowfat Strawberry)"),
        (900, "Kohlrabi"),
        (901, "Kohlrabi (Cooked)"),
        (902, "Squash"),
        (903, "SQUASH"),
      ]
      for (id, name) in rows {
        try db.execute(
          sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (?, ?, 0, 0, 0, 0)",
          arguments: [id, name])
      }
      let aliases: [(Int64, String)] = [
        (168287, "seasoning salt pork"),
        (169884, "glass noodles"),
        (171301, "drinkable kefir"),
        (900, "turnip cabbage"),
        (900, "ambiguous vegetable"),
        (901, "ambiguous vegetable"),
      ]
      for (id, alias) in aliases {
        try db.execute(
          sql: "INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES (?, ?)",
          arguments: [id, alias])
      }
    }
    return IngredientCatalogResolver(db: db)
  }

  func testExactRejectsTheMeasuredFalseClassificationIdentities() throws {
    let resolver = try makeResolver()
    for (label, id) in [("raw_glass", Int64(169884)), ("seasonings", 168287), ("drink", 171301)] {
      XCTAssertNil(resolver.resolve(label, matching: .exact), label)
      XCTAssertEqual(resolver.resolve(label, matching: .allowPrefix), id, label)
    }
  }

  func testExactResolvesUniqueNamesAndAliasesAfterNormalization() throws {
    let resolver = try makeResolver()
    XCTAssertEqual(resolver.resolve("KOHLRABI", matching: .exact), 900)
    XCTAssertEqual(resolver.resolve("turnip_cabbage", matching: .exact), 900)
    XCTAssertEqual(resolver.resolve("raw kohlrabi", matching: .exact), 900)
  }

  func testExactRejectsAmbiguousNamesAndAliases() throws {
    let resolver = try makeResolver()
    XCTAssertNil(resolver.resolve("squash", matching: .exact))
    XCTAssertNil(resolver.resolve("ambiguous vegetable", matching: .exact))
    XCTAssertNil(resolver.resolve("", matching: .exact))
  }

  func testPrefixNameAndOCRFallbackKeepTheirPreviousBehavior() throws {
    let resolver = try makeResolver()
    XCTAssertNil(resolver.resolve("kefir", matching: .exact))
    XCTAssertEqual(resolver.resolve("kefir", matching: .allowPrefix), 171301)
    XCTAssertEqual(resolver.resolveFromText("DRINK"), 171301)
    XCTAssertNil(resolver.resolve("kohlr", matching: .allowPrefix))
  }

  func testClassificationUsesExactCatalogFallback() throws {
    let resolver = try makeResolver()
    XCTAssertNil(IngredientIdentityResolution.resolveLabel(
      "raw_glass", userCorrection: { _ in nil }, curated: IngredientLexicon.resolve,
      catalog: resolver.resolve))
    XCTAssertEqual(IngredientIdentityResolution.resolveLabel(
      "kohlrabi", userCorrection: { _ in nil }, curated: IngredientLexicon.resolve,
      catalog: resolver.resolve), 900)
  }
}
