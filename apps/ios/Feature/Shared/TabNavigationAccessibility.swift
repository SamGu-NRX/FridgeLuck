import SwiftUI

extension EnvironmentValues {
  /// False for a tab that is mounted but not on screen. `ContentView` keeps all four tabs in
  /// one ZStack and hides the inactive ones with opacity.
  @Entry var isTabOnScreen = true
}

extension View {
  /// Apply to each screen a tab's `NavigationStack` shows: its root, and any destination that
  /// can stay pushed while the tab bar is visible. While the tab is off screen the screen leaves
  /// the accessibility tree.
  ///
  /// `.accessibilityHidden` on the tab container does not do this. Each screen in a
  /// `NavigationStack` is hosted separately, and the modifier did not cross into them: with only
  /// that modifier, the UI journey still found Home's Scan Fridge button while Kitchen was on
  /// screen (CI run 38889578085). Setting `accessibilityElementsHidden` on the UIKit navigation
  /// controller's view did not help either (CI run 38892803430).
  func hidesFromAccessibilityWhenTabOffScreen() -> some View {
    modifier(TabScreenAccessibilityModifier())
  }
}

private struct TabScreenAccessibilityModifier: ViewModifier {
  @Environment(\.isTabOnScreen) private var isTabOnScreen

  func body(content: Content) -> some View {
    content.accessibilityHidden(!isTabOnScreen)
  }
}
