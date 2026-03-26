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
  case setupBridge
  case handoff

  var showsTopBarContent: Bool {
    self != .welcome
  }

  var showsFooterActions: Bool {
    self != .welcome && self != .setupBridge
  }

  var backgroundRenderMode: FLAmbientBackgroundRenderMode {
    switch self {
    case .age,
      .goal,
      .calories,
      .restrictions,
      .allergens,
      .healthPermission:
      return .interactive
    default:
      return .live
    }
  }

  var shouldWarmAllergenCatalog: Bool {
    rawValue >= Self.featureChef.rawValue
  }
}
