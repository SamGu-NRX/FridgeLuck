import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

@MainActor
final class NotificationCoordinatorTests: XCTestCase {
  func testRefreshFreshnessOpportunitiesUsesBackendResultsWhenAvailable() async throws {
    let dbQueue = try makeDatabase()
    try insertIngredient(id: 1, name: "spinach", into: dbQueue)

    let inventoryRepository = InventoryRepository(db: dbQueue)
    _ = try inventoryRepository.addLot(
      ingredientId: 1,
      quantityGrams: 120,
      location: .fridge,
      confidenceScore: 1,
      source: .manual,
      acquiredAt: Date(),
      expiresAt: Date().addingTimeInterval(24 * 3600)
    )

    let ruleRepository = NotificationRuleRepository(db: dbQueue)
    let permissionService = MockPermissionService(status: .authorized)
    let center = MockNotificationCenter()
    let scheduler = NotificationScheduler(center: center)
    let syncService = MockNotificationSyncService(
      opportunities: [
        NotificationOpportunity(
          id: "backend-1",
          kind: .useSoonDigest,
          title: "Use these ingredients soon",
          body: "Spinach should be cooked before tomorrow.",
          scheduledAt: Date().addingTimeInterval(300),
          payloadJSON: "{}",
          source: .backend,
          status: .scheduled,
          updatedAt: Date()
        )
      ]
    )
    let coordinator = NotificationCoordinator(
      ruleRepository: ruleRepository,
      permissionService: permissionService,
      scheduler: scheduler,
      syncService: syncService,
      inventoryRepository: inventoryRepository,
      spoilageService: SpoilageService(inventoryRepository: inventoryRepository)
    )

    await coordinator.refreshFreshnessOpportunities()

    let scheduled = try ruleRepository.fetchScheduledOpportunities(after: .distantPast)
    XCTAssertEqual(scheduled.map(\.id), ["backend-1"])
    let identifiers = center.addedRequests.map(\.identifier)
    XCTAssertTrue(identifiers.contains("freshness.backend-1"))
  }

  func testRefreshFreshnessOpportunitiesFallsBackLocallyWhenBackendFails() async throws {
    let dbQueue = try makeDatabase()
    try insertIngredient(id: 2, name: "milk", into: dbQueue)

    let inventoryRepository = InventoryRepository(db: dbQueue)
    _ = try inventoryRepository.addLot(
      ingredientId: 2,
      quantityGrams: 200,
      location: .fridge,
      confidenceScore: 0.9,
      source: .manual,
      acquiredAt: Date(),
      expiresAt: Date().addingTimeInterval(24 * 3600)
    )

    let ruleRepository = NotificationRuleRepository(db: dbQueue)
    let permissionService = MockPermissionService(status: .authorized)
    let center = MockNotificationCenter()
    let scheduler = NotificationScheduler(center: center)
    let syncService = MockNotificationSyncService(error: NSError(domain: "test", code: 1))
    let coordinator = NotificationCoordinator(
      ruleRepository: ruleRepository,
      permissionService: permissionService,
      scheduler: scheduler,
      syncService: syncService,
      inventoryRepository: inventoryRepository,
      spoilageService: SpoilageService(inventoryRepository: inventoryRepository)
    )

    await coordinator.refreshFreshnessOpportunities()

    let scheduled = try ruleRepository.fetchScheduledOpportunities(after: .distantPast)
    XCTAssertEqual(scheduled.count, 1)
    XCTAssertEqual(scheduled.first?.source, .local)
    let identifiers = center.addedRequests.map(\.identifier)
    XCTAssertTrue(identifiers.contains { $0.hasPrefix("freshness.local-use-soon-") })
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    return dbQueue
  }

  private func insertIngredient(id: Int64, name: String, into dbQueue: DatabaseQueue) throws {
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (
            id, name, calories, protein, carbs, fat, fiber, sugar, sodium
          ) VALUES (?, ?, 0, 0, 0, 0, 0, 0, 0)
          """,
        arguments: [id, name]
      )
    }
  }
}

private struct MockPermissionService: NotificationPermissionServicing {
  private let fixedStatus: AppPermissionStatus

  init(status: AppPermissionStatus) {
    self.fixedStatus = status
  }

  @MainActor
  func status() async -> AppPermissionStatus {
    fixedStatus
  }

  @MainActor
  func requestAuthorizationIfNeeded() async -> AppPermissionRequestResult {
    .granted
  }
}

private struct MockNotificationSyncService: NotificationSyncServing {
  private let mockedOpportunities: [NotificationOpportunity]?
  private let mockedError: Error?

  init(opportunities: [NotificationOpportunity]? = nil, error: Error? = nil) {
    self.mockedOpportunities = opportunities
    self.mockedError = error
  }

  func fetchFreshnessOpportunities(
    rule: NotificationRule,
    inventoryItems: [InventoryActiveItem]
  ) async throws -> [NotificationOpportunity]? {
    if let mockedError {
      throw mockedError
    }
    return mockedOpportunities
  }
}
