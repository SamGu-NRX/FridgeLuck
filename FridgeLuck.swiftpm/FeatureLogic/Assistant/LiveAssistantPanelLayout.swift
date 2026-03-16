import CoreGraphics

public enum LiveAssistantPanelDetent: CaseIterable {
  case peek
  case step
  case full

  public func height(in screenHeight: CGFloat) -> CGFloat {
    switch self {
    case .peek:
      return 116
    case .step:
      return screenHeight * 0.38
    case .full:
      return screenHeight * 0.72
    }
  }
}

public enum LiveAssistantPanelLayout {
  public static func clampedHeight(
    for detent: LiveAssistantPanelDetent,
    translation: CGFloat,
    screenHeight: CGFloat
  ) -> CGFloat {
    let minHeight = LiveAssistantPanelDetent.peek.height(in: screenHeight)
    let maxHeight = LiveAssistantPanelDetent.full.height(in: screenHeight)
    let rawHeight = detent.height(in: screenHeight) - translation
    return min(max(rawHeight, minHeight), maxHeight)
  }

  public static func resolvedDetent(
    from detent: LiveAssistantPanelDetent,
    translation: CGFloat,
    predictedEndTranslation: CGFloat,
    screenHeight: CGFloat
  ) -> LiveAssistantPanelDetent {
    let currentHeight = clampedHeight(
      for: detent,
      translation: translation,
      screenHeight: screenHeight
    )
    let projectedHeight = clampedHeight(
      for: detent,
      translation: predictedEndTranslation,
      screenHeight: screenHeight
    )
    let weightedHeight = currentHeight * 0.55 + projectedHeight * 0.45

    return LiveAssistantPanelDetent.allCases.min(by: {
      abs($0.height(in: screenHeight) - weightedHeight)
        < abs($1.height(in: screenHeight) - weightedHeight)
    }) ?? .step
  }
}
