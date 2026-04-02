import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

final class NotificationRuleRepositoryTests: XCTestCase {
  func testDefaultRulesAreSeededWithExpectedDefaults() throws {
    let repository = try makeRepository()

    let rules = try repository.fetchAllRules()

    XCTAssertEqual(rules.map(\.kind), NotificationRuleKind.allCases)
    XCTAssertEqual(try repository.fetchRule(kind: .mealBreakfast).hour, 8)
    XCTAssertEqual(try repository.fetchRule(kind: .mealBreakfast).minute, 30)
    XCTAssertEqual(try repository.fetchRule(kind: .mealBreakfast).enabled, true)
    XCTAssertEqual(try repository.fetchRule(kind: .useSoonAlerts).hour, 18)
    XCTAssertEqual(try repository.fetchRule(kind: .useSoonAlerts).enabled, true)
  }

  func testRuleChangesPersistAcrossReloads() throws {
    let dbQueue = try makeDatabase()
    let repository = NotificationRuleRepository(db: dbQueue)

    _ = try repository.fetchAllRules()
    try repository.saveRule(kind: .mealSnack, enabled: true, hour: 15, minute: 45)

    let reloaded = NotificationRuleRepository(db: dbQueue)
    let snackRule = try reloaded.fetchRule(kind: .mealSnack)
    XCTAssertTrue(snackRule.enabled)
    XCTAssertEqual(snackRule.hour, 15)
    XCTAssertEqual(snackRule.minute, 45)
  }

  func testReplacingFreshnessOpportunitiesDedupesStoredDigestRows() throws {
    let repository = try makeRepository()

    try repository.replaceFreshnessOpportunities(
      with: [
        makeOpportunity(id: "first")
      ]
    )
    try repository.replaceFreshnessOpportunities(
      with: [
        makeOpportunity(id: "second")
      ]
    )

    let scheduled = try repository.fetchScheduledOpportunities(after: .distantPast)
    XCTAssertEqual(scheduled.map(\.id), ["second"])
  }

  private func makeRepository() throws -> NotificationRuleRepository {
    NotificationRuleRepository(db: try makeDatabase())
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    return dbQueue
  }

  private func makeOpportunity(id: String) -> NotificationOpportunity {
    NotificationOpportunity(
      id: id,
      kind: .useSoonDigest,
      title: "Use these ingredients soon",
      body: "Spinach should be cooked soon.",
      scheduledAt: Date().addingTimeInterval(300),
      payloadJSON: "{}",
      source: .local,
      status: .scheduled,
      updatedAt: Date()
    )
  }
}
