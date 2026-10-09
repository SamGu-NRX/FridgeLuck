import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

final class LearningServiceTests: XCTestCase {
  override func setUp() {
    super.setUp()
    for key in ["learning_suggestions_shown", "learning_suggestions_accepted"] {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      let ingredients: [(Int64, String)] = [
        (1, "Test Tomato"),
        (2, "Test Yogurt"),
        (3, "Test Kombucha"),
      ]
      for (id, name) in ingredients {
        try db.execute(
          sql:
            "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (?, ?, 0, 0, 0, 0)",
          arguments: [id, name])
      }
    }
    return db
  }

  private func insertCorrection(
    _ db: DatabaseQueue,
    label: String,
    ingredientId: Int64,
    count: Int,
    lastUsedAt: String
  ) throws {
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO user_corrections
              (vision_label, corrected_ingredient_id, correction_count, last_used_at)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [label, ingredientId, count, lastUsedAt])
    }
  }

  // MARK: - Correction threshold

  func testSingleCorrectionDoesNotAutoCorrect() throws {
    let db = try makeDatabase()
    let service = LearningService(db: db)

    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)

    XCTAssertNil(service.correctedIngredientId(for: "tomato"))
    XCTAssertEqual(service.suggestedCorrection(for: "tomato"), 1)
  }

  func testTwoCorrectionsAutoCorrect() throws {
    let db = try makeDatabase()
    let service = LearningService(db: db)

    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)
    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)

    XCTAssertEqual(service.correctedIngredientId(for: "tomato"), 1)
    XCTAssertEqual(service.suggestedCorrection(for: "tomato"), 1)
  }

  func testMixedTargetCorrectionsDoNotAutoCorrect() throws {
    let db = try makeDatabase()
    let service = LearningService(db: db)

    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)
    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 2)

    XCTAssertNil(service.correctedIngredientId(for: "tomato"))
    XCTAssertEqual(service.suggestedCorrection(for: "tomato"), 2)
  }

  func testSplitThenMajorityAutoCorrects() throws {
    let db = try makeDatabase()
    let service = LearningService(db: db)

    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)
    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 2)
    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)

    XCTAssertEqual(service.correctedIngredientId(for: "tomato"), 1)
    XCTAssertEqual(service.suggestedCorrection(for: "tomato"), 1)
  }

  // MARK: - Label normalization

  func testCorrectionThresholdIsCaseInsensitive() throws {
    let db = try makeDatabase()
    let service = LearningService(db: db)

    service.recordCorrection(visionLabel: "TOMATO", correctedIngredientId: 1)
    service.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)

    XCTAssertEqual(service.correctedIngredientId(for: "tomato"), 1)
    XCTAssertEqual(service.correctedIngredientId(for: "TOMATO"), 1)
  }

  func testCorrectionTrimsWhitespace() throws {
    let db = try makeDatabase()
    let service = LearningService(db: db)

    service.recordCorrection(visionLabel: " Cherry Tomato ", correctedIngredientId: 1)
    service.recordCorrection(visionLabel: " Cherry Tomato ", correctedIngredientId: 1)

    XCTAssertEqual(service.correctedIngredientId(for: "cherry tomato"), 1)
  }

  func testWhitespaceAndCaseAcrossNewInstance() throws {
    let db = try makeDatabase()
    let first = LearningService(db: db)

    first.recordCorrection(visionLabel: " tomato ", correctedIngredientId: 1)
    first.recordCorrection(visionLabel: "TOMATO", correctedIngredientId: 1)

    let second = LearningService(db: db)
    XCTAssertEqual(second.correctedIngredientId(for: "tomato"), 1)
    XCTAssertEqual(first.correctedIngredientId(for: "tomato"), 1)
  }

  // MARK: - Persistence and cache reload

  func testNewInstanceAgreesWithDatabase() throws {
    let db = try makeDatabase()
    let first = LearningService(db: db)

    first.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)
    first.recordCorrection(visionLabel: "tomato", correctedIngredientId: 1)

    let second = LearningService(db: db)
    XCTAssertEqual(second.correctedIngredientId(for: "tomato"), 1)
    XCTAssertEqual(second.suggestedCorrection(for: "tomato"), 1)

    try db.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT correction_count, corrected_ingredient_id
            FROM user_corrections
            WHERE vision_label = 'tomato'
            """)
      else {
        XCTFail("expected a persisted correction row for 'tomato'")
        return
      }
      XCTAssertEqual(row["correction_count"], 2)
      XCTAssertEqual(row["corrected_ingredient_id"], 1)
    }

    XCTAssertEqual(
      first.correctedIngredientId(for: "tomato"),
      second.correctedIngredientId(for: "tomato"))
    XCTAssertEqual(first.suggestedCorrection(for: "tomato"), second.suggestedCorrection(for: "tomato"))
  }

  func testNewInstanceKeepsMostRecentSuggestionOnCountTie() throws {
    let db = try makeDatabase()
    try insertCorrection(
      db, label: "yogurt", ingredientId: 1, count: 1, lastUsedAt: "2026-01-01 00:00:00")
    try insertCorrection(
      db, label: "yogurt", ingredientId: 2, count: 1, lastUsedAt: "2026-02-01 00:00:00")

    let reloaded = LearningService(db: db)
    XCTAssertEqual(reloaded.suggestedCorrection(for: "yogurt"), 2)
  }

  func testHighestCountWinsAfterReload() throws {
    let db = try makeDatabase()
    try insertCorrection(
      db, label: "kombucha", ingredientId: 2, count: 3, lastUsedAt: "2026-01-01 00:00:00")
    try insertCorrection(
      db, label: "kombucha", ingredientId: 1, count: 1, lastUsedAt: "2026-02-01 00:00:00")

    let reloaded = LearningService(db: db)
    XCTAssertEqual(reloaded.suggestedCorrection(for: "kombucha"), 2)
    XCTAssertEqual(reloaded.correctedIngredientId(for: "kombucha"), 2)
  }

  // MARK: - Telemetry

  func testTelemetryCountsAndHitRate() throws {
    let db = try makeDatabase()
    let service = LearningService(db: db)

    service.recordSuggestionShown()
    service.recordSuggestionShown()
    service.recordSuggestionOutcome(accepted: true)
    service.recordSuggestionOutcome(accepted: false)

    let telemetry = service.telemetry()
    XCTAssertEqual(telemetry.suggestionsShown, 2)
    XCTAssertEqual(telemetry.suggestionsAccepted, 1)
    XCTAssertEqual(telemetry.hitRate, 0.5, accuracy: 0.001)
  }

  func testTelemetrySurvivesNewInstance() throws {
    let db = try makeDatabase()
    let first = LearningService(db: db)

    first.recordSuggestionShown()
    first.recordSuggestionShown()
    first.recordSuggestionOutcome(accepted: true)

    let second = LearningService(db: db)
    let telemetry = second.telemetry()
    XCTAssertEqual(telemetry.suggestionsShown, 2)
    XCTAssertEqual(telemetry.suggestionsAccepted, 1)
    XCTAssertEqual(telemetry.hitRate, 0.5, accuracy: 0.001)
  }

  func testTelemetryHitRateZeroWithoutShows() throws {
    let db = try makeDatabase()
    let service = LearningService(db: db)

    var telemetry = service.telemetry()
    XCTAssertEqual(telemetry.suggestionsShown, 0)
    XCTAssertEqual(telemetry.suggestionsAccepted, 0)
    XCTAssertEqual(telemetry.hitRate, 0)

    service.recordSuggestionOutcome(accepted: true)

    telemetry = service.telemetry()
    XCTAssertEqual(telemetry.suggestionsAccepted, 1)
    XCTAssertEqual(telemetry.suggestionsShown, 0)
    XCTAssertEqual(telemetry.hitRate, 0)
  }
}
