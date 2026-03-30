import SwiftUI

@MainActor
@Observable
final class SpotlightCoordinator {
  var activePresentation: SpotlightPresentation? = nil
  var anchors: [String: CGRect] = [:]
  var onScrollToAnchor: ((String) -> Void)? = nil
  var onDismissPresentation: ((SpotlightPresentation) -> Void)? = nil

  func present(steps: [SpotlightStep], source: String) {
    guard !steps.isEmpty else { return }
    activePresentation = SpotlightPresentation(source: source, steps: steps)
  }

  func dismissActivePresentation() {
    guard let activePresentation else { return }
    onDismissPresentation?(activePresentation)
    self.activePresentation = nil
  }

  func updateAnchors(
    _ newAnchors: [String: CGRect],
    retainingExistingValues: Bool = false
  ) {
    let normalizedAnchors = newAnchors.reduce(into: [String: CGRect]()) { partialResult, entry in
      let normalizedRect = entry.value.normalizedForSpotlight
      guard normalizedRect.isUsableSpotlightRect else { return }
      partialResult[entry.key] = normalizedRect
    }

    Task { @MainActor [weak self, normalizedAnchors, retainingExistingValues] in
      guard let self else { return }

      var nextAnchors = retainingExistingValues ? self.anchors : [:]
      for (anchorID, rect) in normalizedAnchors {
        nextAnchors[anchorID] = rect
      }
      guard self.anchors != nextAnchors else { return }
      self.anchors = nextAnchors
    }
  }
}

struct SpotlightAnchorKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]

  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

extension CGRect {
  fileprivate var isUsableSpotlightRect: Bool {
    guard !isEmpty, !isNull, !isInfinite else { return false }
    guard width > 0, height > 0 else { return false }
    return minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
  }

  fileprivate var normalizedForSpotlight: CGRect {
    CGRect(
      x: normalizedSpotlightCoordinate(minX),
      y: normalizedSpotlightCoordinate(minY),
      width: normalizedSpotlightCoordinate(width),
      height: normalizedSpotlightCoordinate(height)
    )
  }

  private func normalizedSpotlightCoordinate(_ value: CGFloat) -> CGFloat {
    (value * 2).rounded() / 2
  }
}

extension View {
  func spotlightAnchor(_ id: String) -> some View {
    background(
      GeometryReader { geo in
        Color.clear.preference(
          key: SpotlightAnchorKey.self,
          value: [id: geo.frame(in: .global)]
        )
      }
    )
  }
}
