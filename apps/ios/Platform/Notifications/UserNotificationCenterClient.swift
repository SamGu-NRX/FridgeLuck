import Foundation
import UserNotifications

/// Returns pending identifiers rather than `UNNotificationRequest`s: Xcode 16's SDK doesn't
/// mark the requests Sendable, so returning them to the scheduler actor fails the Swift 6 build.
protocol UserNotificationCenterClient: Sendable {
  func pendingNotificationIdentifiers() async -> [String]
  func add(_ request: UNNotificationRequest) async throws
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
}

struct SystemUserNotificationCenterClient: UserNotificationCenterClient {
  func pendingNotificationIdentifiers() async -> [String] {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
        continuation.resume(returning: requests.map(\.identifier))
      }
    }
  }

  func add(_ request: UNNotificationRequest) async throws {
    try await UNUserNotificationCenter.current().add(request)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: identifiers)
  }
}
