// Linux-only compatibility declarations for the app-logic subset.
//
// These re-declare small Foundation-level constants whose definition of record
// lives in Apple-coupled files that are not part of the Linux build. Values
// MUST match the iOS definitions exactly; each entry cross-references the
// file it mirrors. Nothing here shims a functional Apple-framework API —
// NotificationCenter is part of Foundation and works on Linux.
//
// When the iOS definition changes, change it here in the same commit.

#if os(Linux)
import Foundation

extension Notification.Name {
  /// Mirrors `NotificationCoordinator.swift` on iOS
  /// (`samgu.FridgeLuck.inventoryDidChange`), which is excluded from the
  /// Linux build because it imports UIKit.
  static let inventoryDidChange = Notification.Name("samgu.FridgeLuck.inventoryDidChange")
}

#endif
