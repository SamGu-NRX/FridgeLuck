import Foundation
import UserNotifications

protocol UserNotificationCenterClient: Sendable {
  func pendingNotificationRequests() async -> [UNNotificationRequest]
  func add(_ request: UNNotificationRequest) async throws
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
}

struct SystemUserNotificationCenterClient: UserNotificationCenterClient {
  func pendingNotificationRequests() async -> [UNNotificationRequest] {
    await UNUserNotificationCenter.current().pendingNotificationRequests()
  }

  func add(_ request: UNNotificationRequest) async throws {
    try await UNUserNotificationCenter.current().add(request)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: identifiers)
  }
}
