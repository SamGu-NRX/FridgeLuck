import Foundation
@preconcurrency import UserNotifications
import XCTest

@testable import FridgeLuck

final class NotificationSchedulerTests: XCTestCase {
  func testReconcileAddsStableIdentifiersForMealAndFreshnessRequests() async throws {
    let center = MockNotificationCenter()
    let scheduler = NotificationScheduler(center: center)

    try await scheduler.reconcile(
      rules: [
        NotificationRule.makeDefault(kind: .mealBreakfast),
        NotificationRule.makeDefault(kind: .mealLunch),
      ],
      opportunities: [
        makeOpportunity(id: "digest-1")
      ],
      permissionStatus: .authorized
    )

    let identifiers = center.addedRequests.map(\.identifier).sorted()
    XCTAssertTrue(identifiers.contains("tracking.meal.breakfast"))
    XCTAssertTrue(identifiers.contains("tracking.meal.lunch"))
    XCTAssertTrue(identifiers.contains("freshness.digest-1"))
  }

  func testDisabledRulesRemovePendingRequestsWithoutReaddingThem() async throws {
    let center = MockNotificationCenter(
      pendingRequests: [
        makePendingRequest(id: "tracking.meal.breakfast"),
        makePendingRequest(id: "freshness.old"),
      ]
    )
    let scheduler = NotificationScheduler(center: center)
    var disabledBreakfast = NotificationRule.makeDefault(kind: .mealBreakfast)
    disabledBreakfast.enabled = false

    try await scheduler.reconcile(
      rules: [disabledBreakfast],
      opportunities: [],
      permissionStatus: .authorized
    )

    let removed = center.removedIdentifiers
    XCTAssertTrue(removed.contains("tracking.meal.breakfast"))
    XCTAssertTrue(removed.contains("freshness.old"))
    let added = center.addedRequests
    XCTAssertFalse(added.map(\.identifier).contains("tracking.meal.breakfast"))
  }

  func testTimeEditsReplaceExistingRequestsInsteadOfDuplicating() async throws {
    let center = MockNotificationCenter(
      pendingRequests: [makePendingRequest(id: "tracking.meal.breakfast")]
    )
    let scheduler = NotificationScheduler(center: center)
    var breakfast = NotificationRule.makeDefault(kind: .mealBreakfast)
    breakfast.hour = 9
    breakfast.minute = 15

    try await scheduler.reconcile(
      rules: [breakfast],
      opportunities: [],
      permissionStatus: .authorized
    )

    let added = center.addedRequests.filter { $0.identifier == "tracking.meal.breakfast" }
    XCTAssertEqual(added.count, 1)
    let removed = center.removedIdentifiers
    XCTAssertTrue(removed.contains("tracking.meal.breakfast"))
  }

  func testReconcileDedupesFreshnessRequestsByReplacingExistingOnes() async throws {
    let center = MockNotificationCenter(
      pendingRequests: [
        makePendingRequest(id: "freshness.stale-1"),
        makePendingRequest(id: "freshness.stale-2"),
      ]
    )
    let scheduler = NotificationScheduler(center: center)

    try await scheduler.reconcile(
      rules: [],
      opportunities: [makeOpportunity(id: "fresh-1")],
      permissionStatus: .authorized
    )

    let removed = center.removedIdentifiers
    XCTAssertTrue(removed.contains("freshness.stale-1"))
    XCTAssertTrue(removed.contains("freshness.stale-2"))
    let addedFreshness = center.addedRequests.filter { $0.identifier.hasPrefix("freshness.") }
    XCTAssertEqual(addedFreshness.map(\.identifier), ["freshness.fresh-1"])
  }

  private func makeOpportunity(id: String) -> NotificationOpportunity {
    NotificationOpportunity(
      id: id,
      kind: .useSoonDigest,
      title: "Use these ingredients soon",
      body: "Cook spinach soon.",
      scheduledAt: Date().addingTimeInterval(600),
      payloadJSON: "{}",
      source: .backend,
      status: .scheduled,
      updatedAt: Date()
    )
  }

  private func makePendingRequest(id: String) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "Test"
    return UNNotificationRequest(
      identifier: id,
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
    )
  }
}

final class MockNotificationCenter: @unchecked Sendable, UserNotificationCenterClient {
  private(set) var pendingRequests: [UNNotificationRequest]
  private(set) var addedRequests: [UNNotificationRequest] = []
  private(set) var removedIdentifiers: [String] = []

  init(pendingRequests: [UNNotificationRequest] = []) {
    self.pendingRequests = pendingRequests
  }

  func pendingNotificationRequests() async -> [UNNotificationRequest] {
    pendingRequests
  }

  func add(_ request: UNNotificationRequest) async throws {
    addedRequests.append(request)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
    removedIdentifiers.append(contentsOf: identifiers)
    pendingRequests.removeAll { identifiers.contains($0.identifier) }
  }
}
