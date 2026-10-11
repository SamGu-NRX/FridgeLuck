import Foundation
import GRDB
import XCTest

@testable import CookbookFlowCheck
@testable import FLFeatureLogic

/// Shared fixtures for the cookbook flow check.
///
/// Every test database is built by the REAL `DatabaseMigrations` (v1 through v20)
/// with foreign keys enabled, exactly as `AppDatabase.setup` does — the check
/// must pass against production schema, never a parallel fixture schema.
enum TestSupport {
  /// A fresh migrated database in a temp directory, foreign keys on.
  static func makeDatabaseQueue() throws -> DatabaseQueue {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("cookbook-flow-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var config = Configuration()
    config.foreignKeysEnabled = true
    let dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("test.sqlite").path)
    try DatabaseMigrations.migrate(dbQueue)
    return dbQueue
  }

  /// Inserts a catalog ingredient and returns its row id.
  @discardableResult
  static func seedIngredient(
    _ dbQueue: DatabaseQueue, name: String, calories: Double = 50
  ) throws -> Int64 {
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (name, calories, protein, carbs, fat, fiber, sugar, sodium)
          VALUES (?, ?, 0, 0, 0, 0, 0, 0)
          """,
        arguments: [name, calories])
      return db.lastInsertedRowID
    }
  }

  /// Inserts a recipe row directly (bypassing the service), for cases that need
  /// a pre-existing row with a specific provenance.
  @discardableResult
  static func seedRecipe(
    _ dbQueue: DatabaseQueue,
    title: String,
    timeMinutes: Int = 10,
    servings: Int = 1,
    instructions: String = "Cook it.",
    tags: Int = 0,
    source: String
  ) throws -> Int64 {
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (title, time_minutes, servings, instructions, tags, source)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [title, timeMinutes, servings, instructions, tags, source])
      return db.lastInsertedRowID
    }
  }

  static func count(
    _ dbQueue: DatabaseQueue, _ sql: String, _ arguments: StatementArguments? = nil
  ) throws -> Int {
    try dbQueue.read { db in
      try Int.fetchOne(db, sql: sql, arguments: arguments ?? StatementArguments()) ?? -1
    }
  }
}

/// A valid two-line draft used across transaction tests.
enum TestDrafts {
  static func validDraft(eggId: Int64, riceId: Int64) -> CookbookRecipeDraft {
    CookbookRecipeDraft(
      title: "Sunday Eggs",
      timeMinutes: 12,
      servings: 2,
      instructions: "Fry the eggs. Serve over rice.",
      tagMask: 0,
      ingredientLines: [
        CookbookIngredientLine(ingredientId: eggId, grams: 120, isRequired: true),
        CookbookIngredientLine(ingredientId: riceId, grams: 80.5, isRequired: false),
      ])
  }
}

