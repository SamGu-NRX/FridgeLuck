enum OnboardingStep: Int, CaseIterable {
  case welcome
  case name
  case personalWelcome
  case age
  case goal
  case featureScan
  case calories
  case restrictions
  case featureChef
  case allergens
  case healthValue
  case healthPermission
  case virtualFridgeIntro
  case fridgeCapture
  case pantryCapture
  case kitchenReview
  case setupBridge
  case handoff

  /// Where Back goes. The setup bridge replays and moves forward on its own, so Back from the
  /// final step skips it and returns to the kitchen review.
  var backStep: OnboardingStep? {
    switch self {
    case .welcome: return nil
    case .handoff: return .kitchenReview
    default: return OnboardingStep(rawValue: rawValue - 1)
    }
  }

  var showsTopBarContent: Bool {
    self != .welcome
  }

  var showsFooterActions: Bool {
    self != .welcome && self != .setupBridge && self != .kitchenReview
  }

  var backgroundRenderMode: FLAmbientBackgroundRenderMode {
    switch self {
    case .age,
      .goal,
      .calories,
      .restrictions,
      .allergens,
      .healthPermission,
      .fridgeCapture,
      .pantryCapture:
      return .interactive
    case .virtualFridgeIntro:
      return .live
    default:
      return .live
    }
  }

  var shouldWarmAllergenCatalog: Bool {
    rawValue >= Self.featureChef.rawValue
  }
}
