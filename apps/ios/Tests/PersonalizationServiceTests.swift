import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

final class PersonalizationServiceTests: XCTestCase {
  func testCurrentStreakCountsYesterdayAsOngoing() throws {
    let dbQueue = try makeDatabase()
    let service = PersonalizationService(db: dbQueue)
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    try insertStreak(
      on: calendar.date(byAdding: .day, value: -1, to: today)!,
      into: dbQueue
    )
    try insertStreak(
      on: calendar.date(byAdding: .day, value: -2, to: today)!,
      into: dbQueue
    )

    XCTAssertEqual(try service.currentStreak(), 2)
  }

  func testCurrentStreakIgnoresFutureRowsAndStopsAfterGaps() throws {
    let dbQueue = try makeDatabase()
    let service = PersonalizationService(db: dbQueue)
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    try insertStreak(
      on: calendar.date(byAdding: .day, value: 1, to: today)!,
      into: dbQueue
    )
    try insertStreak(
      on: calendar.date(byAdding: .day, value: -1, to: today)!,
      into: dbQueue
    )
    try insertStreak(
      on: calendar.date(byAdding: .day, value: -3, to: today)!,
      into: dbQueue
    )

    XCTAssertEqual(try service.currentStreak(), 1)
  }

  func testRecordCookingStoresTimestampVisibleToTodayQueries() throws {
    let dbQueue = try makeMigratedDatabaseWithRecipe()
    let service = PersonalizationService(db: dbQueue)

    let historyID = try service.recordCooking(recipeId: 1, servingsConsumed: 2)

    try dbQueue.read { db in
      let cookedToday = try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM cooking_history
          WHERE id = ? AND date(cooked_at, 'localtime') = date('now', 'localtime')
          """,
        arguments: [historyID]
      )
      XCTAssertEqual(cookedToday, 1)
    }
  }

  func testRecordCookingReturnsHistoryIDWhenItAlsoCreatesTodaysStreak() throws {
    let dbQueue = try makeMigratedDatabaseWithRecipe()
    let service = PersonalizationService(db: dbQueue)
    // Earlier streak rows make a streak row ID differ from the history row ID.
    try insertStreak(on: Date(timeIntervalSinceNow: -2 * 86_400), into: dbQueue)
    try insertStreak(on: Date(timeIntervalSinceNow: -86_400), into: dbQueue)

    let firstID = try service.recordCooking(recipeId: 1)
    let secondID = try service.recordCooking(recipeId: 1)

    let storedIDs = try dbQueue.read { db in
      try Int64.fetchAll(db, sql: "SELECT id FROM cooking_history ORDER BY id")
    }
    XCTAssertEqual(storedIDs, [firstID, secondID])
  }

  private func makeMigratedDatabaseWithRecipe() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Test Rice', 10, 1, 'Cook.')
          """
      )
    }
    return dbQueue
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
      try db.create(table: Streak.databaseTableName) { table in
        table.column("date", .text).primaryKey()
        table.column("meals_cooked", .integer).notNull()
      }
    }
    return dbQueue
  }

  private func insertStreak(on date: Date, into dbQueue: DatabaseQueue) throws {
    try dbQueue.write { db in
      try Streak(
        date: streakDateFormatter.string(from: date),
        mealsCookedCount: 1
      ).insert(db)
    }
  }

  private var streakDateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }
}
