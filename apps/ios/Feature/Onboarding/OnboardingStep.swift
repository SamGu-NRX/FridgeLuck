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
