import Foundation

/// Sequences "Start cooking" from the recipe preview sheet into the full-screen cooking guide,
/// and decides where the user lands when the guide closes.
///
/// SwiftUI drops a full-screen cover requested while a sheet is still dismissing, so the
/// request is held until the preview sheet reports it has dismissed.
public struct CookingLaunchFlow<Item> {
  /// The recipe the guide is showing. Bound to the full-screen cover.
  public var cooking: Item?
  private var requested: Item?
  private var didComplete = false

  public init() {}

  /// The user tapped "Start cooking" in the preview. The caller then dismisses the preview.
  public mutating func requestStart(_ item: Item) {
    requested = item
  }

  /// Call from the preview sheet's onDismiss. Opens the guide only if cooking was requested,
  /// so swiping the preview away or choosing Le Chef does nothing here.
  public mutating func previewDidDismiss() {
    guard let item = requested else { return }
    requested = nil
    didComplete = false
    cooking = item
  }

  /// The user reached the end of the guide and closed its celebration screen.
  public mutating func guideCompleted() {
    didComplete = true
  }

  /// Call from the guide's onDismiss. Returns true when the user finished cooking and should
  /// return Home; false when they closed the guide early and should stay on the results.
  public mutating func guideDidDismiss() -> Bool {
    let shouldReturnHome = didComplete
    cooking = nil
    didComplete = false
    return shouldReturnHome
  }
}
