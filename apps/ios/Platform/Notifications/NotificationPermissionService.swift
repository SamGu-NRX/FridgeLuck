import Foundation

protocol NotificationPermissionServicing: Sendable {
  @MainActor func status() async -> AppPermissionStatus
  @MainActor func requestAuthorizationIfNeeded() async -> AppPermissionRequestResult
}

@MainActor
final class NotificationPermissionService: NotificationPermissionServicing {
  func status() async -> AppPermissionStatus {
    await AppPermissionCenter.notificationStatus()
  }

  func requestAuthorizationIfNeeded() async -> AppPermissionRequestResult {
    await AppPermissionCenter.request(.notifications)
  }
}
