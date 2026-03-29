import SwiftUI

private enum OnboardingTransitionStyle {
  case softFade
  case directionalSlide
}

enum OnboardingTransitionPolicy {
  static func transition(
    from previousStep: OnboardingStep,
    to currentStep: OnboardingStep,
    isForward: Bool,
    reduceMotion: Bool
  ) -> AnyTransition {
    guard !reduceMotion else { return .opacity }

    switch style(from: previousStep, to: currentStep) {
    case .softFade:
      return .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)),
        removal: .opacity
      )
    case .directionalSlide:
      if isForward {
        return .asymmetric(
          insertion: .move(edge: .trailing).combined(with: .opacity),
          removal: .move(edge: .leading).combined(with: .opacity)
        )
      }

      return .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity),
        removal: .move(edge: .trailing).combined(with: .opacity)
      )
    }
  }

  private static func style(from previousStep: OnboardingStep, to currentStep: OnboardingStep)
    -> OnboardingTransitionStyle
  {
    switch (previousStep, currentStep) {
    case (.welcome, .name),
      (.name, .welcome),
      (.name, .personalWelcome),
      (.personalWelcome, .name),
      (.healthPermission, .virtualFridgeIntro),
      (.virtualFridgeIntro, .healthPermission),
      (.virtualFridgeIntro, .fridgeCapture),
      (.fridgeCapture, .virtualFridgeIntro),
      (.kitchenReview, .setupBridge),
      (.setupBridge, .kitchenReview):
      return .softFade
    default:
      return .directionalSlide
    }
  }
}
