import SwiftUI
import UIKit

extension EnvironmentValues {
  /// False for a tab that is mounted but not on screen. `ContentView` keeps all four tabs in
  /// one ZStack and hides the inactive ones with opacity.
  @Entry var isTabOnScreen = true
}

extension View {
  /// Apply to the root view of a tab's `NavigationStack`. While the tab is off screen, its whole
  /// navigation stack (bar, root and pushed screens) leaves the accessibility tree.
  ///
  /// `.accessibilityHidden` on the tab container is not enough: each `NavigationStack` is a
  /// UIKit navigation controller, and the SwiftUI modifier did not reach into it. With only
  /// that modifier, the UI journey still found Home's Scan Fridge button while Kitchen was on
  /// screen (CI run 38889578085).
  func hidesTabNavigationFromAccessibilityWhenOffScreen() -> some View {
    modifier(TabNavigationAccessibilityModifier())
  }
}

/// Reads the environment here, in a view, and hands the probe a plain value, so a tab switch
/// changes the probe's input and SwiftUI calls `updateUIView`.
private struct TabNavigationAccessibilityModifier: ViewModifier {
  @Environment(\.isTabOnScreen) private var isTabOnScreen

  func body(content: Content) -> some View {
    content.background(TabNavigationAccessibilityProbe(hidesNavigationStack: !isTabOnScreen))
  }
}

private struct TabNavigationAccessibilityProbe: UIViewRepresentable {
  let hidesNavigationStack: Bool

  func makeUIView(context: Context) -> ProbeView {
    ProbeView()
  }

  func updateUIView(_ view: ProbeView, context: Context) {
    view.hidesNavigationStack = hidesNavigationStack
  }

  final class ProbeView: UIView {
    var hidesNavigationStack = false {
      didSet { apply() }
    }

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      apply()
    }

    private func apply() {
      var responder: UIResponder? = next
      while let current = responder, !(current is UINavigationController) {
        responder = current.next
      }
      (responder as? UINavigationController)?.view.accessibilityElementsHidden =
        hidesNavigationStack
    }
  }
}
