import XCTest
import GRDB
@testable import SearchCheck

/// Thread-safe mutable epoch holder. `@Sendable` closures may only capture
/// `let` constants or Sendable references, so tests that simulate an epoch
/// change hold it in this box instead of a local `var`.
final class TestEpochBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  init(_ value: String?) {
    self.value = value
  }

  func get() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ value: String?) {
    lock.lock()
    defer { lock.unlock() }
    self.value = value
  }
}

/// Shared fixtures: a fully migrated source database with seeded records, a
/// stub hit resolver, and loading of the frozen eval corpus.
enum SearchFixtures {
  /// A source database world matching the production wiring.
  struct World {
    let db: DatabaseQueue
    let ingredientRepository: IngredientRepository
    let inventoryRepository: InventoryRepository
    let recipeRepository: RecipeRepository
    let userDataRepository: UserDataRepository
    let sources: SearchSources
  }

  /// Creates a migrated in-memory database with three ingredients (one with
  /// an alias), one recipe, one live inventory item, and one journal entry.
  static func makeWorld() throws -> World {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)

    var chicken = Ingredient.fixture(name: "Chicken Breast", category: "protein")
    var egg = Ingredient.fixture(name: "Whole Egg", category: "protein")
    var soySauce = Ingredient.fixture(name: "Soy Sauce", category: "condiment")
    try db.write { db in
      try chicken.insert(db)
      try egg.insert(db)
      try soySauce.insert(db)
    }
    // Codable PersistableRecord has no didInsert write-back, so IDs are read
    // back from the database after insertion.
    func ingredientID(_ name: String) throws -> Int64 {
      try db.read { db in
        guard let id = try Int64.fetchOne(
          db,
          sql: "SELECT id FROM ingredients WHERE name = ?",
          arguments: [name])
        else { throw CancellationError() }
        return id
      }
    }
    let chickenID = try ingredientID("Chicken Breast")
    _ = try ingredientID("Whole Egg")
    _ = try ingredientID("Soy Sauce")
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES (?, ?)",
        arguments: [chickenID, "chicken"])
    }

    let ingredientRepository = IngredientRepository(db: db)
    let inventoryRepository = InventoryRepository(db: db)
    let nutritionService = NutritionService(db: db)
    let recipeRepository = RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: HealthScoringService(nutritionService: nutritionService, db: db),
      personalizationService: PersonalizationService(db: db))
    let userDataRepository = UserDataRepository(db: db)

    let recipe = Recipe(
      id: nil,
      title: "Garlic Chicken",
      timeMinutes: 30,
      servings: 2,
      instructions: "Cook it.",
      tags: 0,
      source: .user,
      createdAt: Date(timeIntervalSince1970: 1_780_000_000))
    _ = try recipeRepository.saveRecipe(recipe, ingredients: [])

    _ = try inventoryRepository.addLot(
      ingredientId: chickenID,
      quantityGrams: 350,
      location: .fridge,
      confidenceScore: 0.9,
      source: .manual,
      expiresAt: Date(timeIntervalSince1970: 1_790_000_000))

    // The journal aggregate path enforces the snapshot-readiness contract,
    // so the fixture captures a current-version snapshot through the
    // production service after inserting the history row.
    let snapshotService = NutritionSnapshotService(db: db)
    let recipeID = try db.read { db -> Int64 in
      guard let id = try Int64.fetchOne(
        db,
        sql: "SELECT id FROM recipes WHERE title = ?",
        arguments: ["Garlic Chicken"])
      else { throw CancellationError() }
      return id
    }
    let historyID = try db.write { db -> Int64 in
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, cooked_at, rating) VALUES (?, ?, ?)",
        arguments: [recipeID, Date(timeIntervalSince1970: 1_780_358_400), 4])
      return db.lastInsertedRowID
    }
    try db.write { db in
      try snapshotService.captureSnapshot(
        in: db, historyId: historyID, recipeId: recipeID)
    }

    let sources = SearchSources(
      db: db,
      ingredientRepository: ingredientRepository,
      inventoryRepository: inventoryRepository,
      recipeRepository: recipeRepository)

    return World(
      db: db,
      ingredientRepository: ingredientRepository,
      inventoryRepository: inventoryRepository,
      recipeRepository: recipeRepository,
      userDataRepository: userDataRepository,
      sources: sources)
  }

  /// A temp directory for file-backed index databases.
  static func makeTempDirectory(_ name: String) -> String {
    let dir = NSTemporaryDirectory() + "/unified-search-\(name)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  /// A document with sensible defaults for tests.
  static func doc(
    _ kind: SearchRecordKind,
    _ id: String,
    title: String,
    subtitle: String? = nil,
    keywords: String = "",
    dateTokens: String = "",
    revision: Int64 = 0
  ) -> SearchDocument {
    SearchDocument(
      canonicalID: SearchCanonicalID(kind: kind, rawID: id),
      title: title,
      subtitle: subtitle,
      keywords: keywords,
      dateTokens: dateTokens,
      revision: revision)
  }
}

extension Ingredient {
  static func fixture(name: String, category: String?) -> Ingredient {
    Ingredient(
      id: nil,
      name: name,
      calories: 100,
      protein: 10,
      carbs: 10,
      fat: 10,
      fiber: 0,
      sugar: 0,
      sodium: 0,
      typicalUnit: nil,
      storageTip: nil,
      pairsWith: nil,
      notes: nil,
      description: nil,
      categoryLabel: category,
      spriteGroup: nil,
      spriteKey: nil)
  }
}

/// Resolver stub with an explicit live-record set so tests control exactly
/// which hits survive revalidation.
final class StubSearchHitResolving: SearchHitResolving, @unchecked Sendable {
  var liveIDs: Set<String> = []
  var revisions: [String: Int64] = [:]
  private let lock = NSLock()

  init(liveIDs: Set<String> = []) {
    self.liveIDs = liveIDs
  }

  func resolve(_ hit: SearchHit) throws -> SearchResolvedTarget? {
    lock.lock(); defer { lock.unlock() }
    guard liveIDs.contains(hit.canonicalID.description) else { return nil }
    return .recipe(
      Recipe(
        id: 1,
        title: hit.title,
        timeMinutes: 1,
        servings: 1,
        instructions: "",
        tags: 0,
        source: .user,
        createdAt: nil))
  }

  func liveRevision(for hit: SearchHit) throws -> Int64? {
    lock.lock(); defer { lock.unlock() }
    return revisions[hit.canonicalID.description]
  }
}

// MARK: - Frozen eval corpus

struct EvalCorpusDoc: Codable {
  let kind: String
  let canonicalID: String
  let title: String
  let subtitle: String
  let keywords: String
  let dateTokens: String
}

struct EvalCorpusQuery: Codable {
  let q: String
  let expected: [String]
}

struct EvalCorpus: Codable {
  let version: String
  let counts: [String: Int]
  let docs: [EvalCorpusDoc]
  let queries: [EvalCorpusQuery]

  static func load() throws -> EvalCorpus {
    guard let url = Bundle.module.url(
      forResource: "corpus", withExtension: "json", subdirectory: "Fixtures")
    else {
      XCTFail("corpus.json fixture missing")
      throw CancellationError()
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(EvalCorpus.self, from: data)
  }

  /// Converts corpus rows into typed documents with a deterministic revision.
  var documents: [SearchDocument] {
    docs.map { row in
      guard let kind = SearchRecordKind(rawValue: row.kind),
        let id = SearchCanonicalID(parsing: row.canonicalID),
        id.kind == kind
      else {
        fatalError("corpus row has malformed id/kind: \(row.canonicalID) \(row.kind)")
      }
      return SearchDocument(
        canonicalID: id,
        title: row.title,
        subtitle: row.subtitle,
        keywords: row.keywords,
        dateTokens: row.dateTokens,
        revision: SearchText.stableHash(row.canonicalID))
    }
  }
}
