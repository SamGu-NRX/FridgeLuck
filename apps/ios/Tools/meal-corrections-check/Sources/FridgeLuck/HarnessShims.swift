// Harness-only shim — not part of the app. The app defines this notification name in
// Platform/Notifications/NotificationCoordinator.swift, which imports UIKit and cannot
// join this portable harness. The raw value matches the app's exactly.
import Foundation

extension Notification.Name {
  static let inventoryDidChange = Notification.Name("samgu.FridgeLuck.inventoryDidChange")
}
