import Foundation

// Check shim: the real extension lives in NotificationCoordinator.swift,
// which pulls in UserNotifications and cannot compile on Linux.
extension Notification.Name {
  static let inventoryDidChange = Notification.Name("samgu.FridgeLuck.inventoryDidChange")
}
