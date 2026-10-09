import Foundation

// FLInventoryCore compiles InventoryRepository without UIKit, but the repository posts
// `.inventoryDidChange`, a name the app declares in NotificationCoordinator (a UIKit file).
// This Foundation-only stand-in keeps the package target buildable on Linux so the inventory
// invariant tests can run under `swift test`. No Xcode target globs Tools/, so Apple builds
// only ever see the NotificationCoordinator declaration.
#if !canImport(UIKit)
extension Notification.Name {
  static let inventoryDidChange = Notification.Name("samgu.FridgeLuck.inventoryDidChange")
}
#endif
