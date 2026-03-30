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
