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
  /// UIKit navigation controller, and the SwiftUI modifier did not reach into it. A simulator
  /// walk at this branch's first commit still listed Kitchen, Progress and Settings content,
  /// including the Settings navigation bar, while Home was on screen.
  func hidesTabNavigationFromAccessibilityWhenOffScreen() -> some View {
    background(TabNavigationAccessibilityProbe())
  }
}

private struct TabNavigationAccessibilityProbe: UIViewRepresentable {
  func makeUIView(context: Context) -> ProbeView {
    ProbeView()
  }

  func updateUIView(_ view: ProbeView, context: Context) {
    view.hidesNavigationStack = !context.environment.isTabOnScreen
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
