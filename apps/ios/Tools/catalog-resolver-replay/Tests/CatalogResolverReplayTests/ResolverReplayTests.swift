import GRDB
import XCTest

@testable import CatalogReplayCore

/// GRDB-backed behavior tests for the mirrored production resolver. These run
/// the REAL SQL through GRDB's runtime — the path the lexicon probe could not
/// link and the report previously verified only at the SQL level.
final class ResolverReplayTests: XCTestCase {
  private var queue: DatabaseQueue!
  private var resolver: IngredientCatalogResolver!

  override func setUpWithError() throws {
    let path = NSTemporaryDirectory() + "catalog-replay-tests-\(UUID().uuidString).sqlite"
    queue = try DatabaseQueue(path: path)
    try queue.write { db in
      try db.create(table: "ingredients") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull()
      }
      try db.create(table: "ingredient_aliases") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("ingredient_id", .integer).notNull().references("ingredients", onDelete: .cascade)
        t.column("alias", .text).notNull()
      }
      try db.execute(
        sql: "INSERT INTO ingredients (name) VALUES (?)",
        arguments: ["tomato"]
      )
      try db.execute(
        sql: "INSERT INTO ingredients (name) VALUES (?)",
        arguments: ["strawberry"]
      )
      try db.execute(
        sql: "INSERT INTO ingredients (name) VALUES (?)",
        arguments: ["eggplant"]
      )
      try db.execute(
        sql: "INSERT INTO ingredients (name) VALUES (?)",
        arguments: ["bell_pepper"]
      )
      try db.execute(
        sql: "INSERT INTO ingredients (name) VALUES (?)",
        arguments: ["green pepper"]
      )
      try db.execute(
        sql: "INSERT INTO ingredients (name) VALUES (?)",
        arguments: ["red pepper"]
      )
      try db.execute(
        sql: "INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES (?, ?)",
        arguments: [3, "aubergine"]
      )
      try db.execute(
        sql: "INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES (?, ?)",
        arguments: [5, "pepper"]
      )
      try db.execute(
        sql: "INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES (?, ?)",
        arguments: [6, "pepper"]
      )
    }
    resolver = IngredientCatalogResolver(db: queue)
  }

  func testExactNameMatch() throws {
    XCTAssertEqual(resolver.resolve("tomato", matching: .exact), 1)
  }

  func testAliasMatchesInExactModeThroughUnion() throws {
    XCTAssertEqual(resolver.resolve("aubergine", matching: .exact), 3)
  }

  func testAmbiguousAliasReturnsNil() throws {
    // "pepper" aliases two ingredients: ambiguous → nil in both modes
    XCTAssertNil(resolver.resolve("pepper", matching: .exact))
    XCTAssertNil(resolver.resolve("pepper", matching: .allowPrefix))
  }

  func testPluralCandidate() throws {
    XCTAssertEqual(resolver.resolve("tomatoes", matching: .allowPrefix), 1)
  }

  func testPrefixRequiresFiveCharactersAndAllowPrefixMode() throws {
    XCTAssertEqual(resolver.resolve("strawber", matching: .allowPrefix), 2)
    XCTAssertNil(resolver.resolve("strawber", matching: .exact))
    // 4-character candidates never reach the prefix stages
    XCTAssertNil(resolver.resolve("stra", matching: .allowPrefix))
  }

  func testStopWordTrimmedCandidate() throws {
    XCTAssertEqual(resolver.resolve("fresh tomato", matching: .allowPrefix), 1)
  }

  func testResolveFromTextLongestWindowWins() throws {
    XCTAssertEqual(resolver.resolveFromText("slice fresh strawberries please"), 2)
    XCTAssertNil(resolver.resolveFromText("nothing matches this"))
    XCTAssertNil(resolver.resolveFromText("   "))
  }

  func testDisplayNameCasing() throws {
    XCTAssertEqual(resolver.displayName(for: 4), "Bell Pepper")
    XCTAssertEqual(resolver.displayName(for: 5), "Green Pepper")
    XCTAssertNil(resolver.displayName(for: 999))
  }

  func testNormalizedCandidatesDeduplicateThroughResolve() {
    // normalizedCandidates is private in the production source (mirror must
    // stay byte-identical), so candidate handling is exercised via resolve
    XCTAssertEqual(resolver.resolve("tomatoes", matching: .exact), 1)
    XCTAssertNil(resolver.resolve("tomatoess", matching: .allowPrefix))
  }

  func testSourceManifestPinnedFileExists() {
    // The mirror must contain exactly the pinned production file(s).
    XCTAssertEqual(Set(SourceManifest.sha256.keys), ["IngredientCatalogResolver.swift"])
    XCTAssertFalse(SourceManifest.sha256["IngredientCatalogResolver.swift"]!.isEmpty)
    XCTAssertEqual(SourceManifest.upstream, "apps/ios/Capability/Core/Recognition/IngredientCatalogResolver.swift")
  }
}
