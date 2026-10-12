import Foundation

// The operational Home flow state contract (FL4).
//
// Home used to fork its dashboard on `tutorialProgress.isComplete`, which conflated
// learning progress with data existence: a user who stocked a real fridge but skipped
// the tour saw quest cards instead of a kitchen. This file replaces that gate with a
// pure, total state map over the public repository outputs the dashboard already loads.
//
// Two rules hold here and must keep holding:
//
// 1. **Repository outputs only.** Every input is a value a repository or service
//    already returns. Learning progress is not an input — the state map never
//    consults `TutorialProgress`, and nothing in this file may start doing so.
//    The single non-repository signal, a live cook context, arrives as a separate
//    parameter supplied by the view layer from the Live Assistant coordinator.
// 2. **Unknown is nil, never zero.** Freshness is expiry-date based. An item with
//    no known expiry carries `daysUntilExpiry == nil` and produces no use-soon
//    urgency at all; the map never substitutes zero for an unknown.

// MARK: - Inputs

/// The public repository outputs the Home flow reads, in one value.
///
/// Built by `HomeFlowReadModel` in a single pass. `Sendable` and `Equatable` so the
/// map is trivially pure and the view model can compare loads. The domain extensions
/// at the bottom of this file add `Equatable` where the domain types do not declare
/// it; they compare stored fields and add nothing.
struct HomeFlowInputs: Sendable, Equatable {
  /// `UserDataRepository.hasCompletedOnboarding()`
  let hasCompletedOnboarding: Bool
  /// `InventoryRepository.fetchAllActiveItems()` — expiry fields are optional; an
  /// unknown expiry is nil here, never zero.
  let inventoryItems: [InventoryActiveItem]
  /// `SpoilageService.useSoonSuggestions(withinDays: 3, limit: 3)` — only items with
  /// a known, upcoming expiry can appear; unknown expiry never enters this list.
  let useSoon: [InventoryUseSoonSuggestion]
  /// `UserDataRepository.totalMealsCooked()` — durable evidence of a returning user.
  let totalMealsCooked: Int
  /// `UserDataRepository.mealsCooked(lastDays: 7)`
  let mealsCookedLast7Days: Int
  /// `UserDataRepository.cookingJournal(limit: 1).first`
  let latestJournalEntry: CookingJournalEntry?
  /// `UserDataRepository.todayMacros()` — zero means genuinely none logged today.
  let todayMacros: MacroTotals
  /// `PersonalizationService.currentStreak()`
  let currentStreak: Int
  /// `PersonalizationService.weekActivity()`
  let weekActivity: [Bool]
  /// `UserDataRepository.fetchHealthProfile()` — nil before onboarding completes.
  let healthProfile: HealthProfile?
  /// Primary recommendation assembled from `RecommendationPolicy.effectiveIngredientIDs`
  /// → `RecipeRepository.findMakeable` / `findNearMatch`, as the dashboard does today.
  let primaryRecommendation: HomeRecommendation?
  /// The recommendations after the primary, in ranking order.
  let fallbackOptions: [HomeRecommendation]
}

// MARK: - Cook context

/// The one live cooking signal on this branch.
///
/// No persisted active-cook record exists; the Live Assistant coordinator surfaces
/// its matched recipe context as a plain value, and the view layer hands that value
/// here. The state map stays repository-pure: it sees this struct, never the
/// coordinator.
struct HomeCookContext: Sendable, Equatable {
  let recipeName: String?
}

// MARK: - State

/// The five operational states Home resolves to.
///
/// Precedence: `error` > `cooking` > `returning` > `emptyNew` > `partlyStocked`.
/// `totalMealsCooked` is durable evidence, so `returning` ranks above the two
/// empty-stock states. Exhaustively matched — adding a case must break compilation
/// at every consumer.
enum HomeFlowState: Equatable, Sendable {
  /// Kitchen confirmed, nothing stocked, no meals yet.
  case emptyNew
  /// Some stock, no meals yet.
  case partlyStocked
  /// A live cook context is present; it overrides any data state.
  case cooking(HomeCookContext?)
  /// At least one meal cooked — durable evidence of a returning user.
  case returning
  /// Load failed with no last-good inputs; the only state with a retry path.
  case error
}

/// The action Home leads with in a given state, chosen from data — never a placeholder.
/// Each action routes to an existing Home callback; see the state map below.
enum HomeFlowPrimaryAction: Equatable, Sendable {
  case completeProfile  // → onCompleteProfile
  case scanKitchen  // → onScan
  case cook(HomeRecommendation)  // → onOpenRecommendation
  case restock  // → onOpenVirtualFridge
  case resumeCook  // → onOpenAssistant
  case retry  // → HomeFlowViewModel.retry()
}

// MARK: - State map

/// The pure, total map from repository outputs to one Home state and one primary action.
///
/// Identical inputs always resolve to the identical state. There is no default branch:
/// the switch in `primaryAction(for:inputs:)` covers every `HomeFlowState` case, so a
/// future state cannot silently fall through.
enum HomeFlowStateMap {
  /// Resolve the state. `inputs == nil` is the error state — a load that threw with no
  /// last-good result. A present cook context overrides any data state; when it ends,
  /// the same inputs re-map to the underlying data state.
  static func state(inputs: HomeFlowInputs?, cookContext: HomeCookContext?) -> HomeFlowState {
    guard let inputs else { return .error }
    if let cookContext { return .cooking(cookContext) }
    if inputs.totalMealsCooked > 0 { return .returning }
    // NOTE: `inventoryItems` is quantity evidence — active lots with remaining
    // grams > 0. The snapshot projection below reads the same evidence from
    // `stockedIngredientCount`, so both paths agree.
    if inputs.inventoryItems.isEmpty { return .emptyNew }
    return .partlyStocked
  }

  /// The action Home leads with, chosen from data — never a placeholder.
  static func primaryAction(
    for state: HomeFlowState,
    inputs: HomeFlowInputs?
  ) -> HomeFlowPrimaryAction {
    switch state {
    case .error:
      return .retry
    case .cooking:
      return .resumeCook
    case .emptyNew:
      if inputs?.healthProfile == nil { return .completeProfile }
      return .scanKitchen
    case .partlyStocked:
      if let recipe = inputs?.primaryRecommendation { return .cook(recipe) }
      return .scanKitchen
    case .returning:
      guard let inputs else { return .retry }
      if inputs.inventoryItems.isEmpty { return .restock }
      if let recipe = inputs.primaryRecommendation { return .cook(recipe) }
      return .scanKitchen
    }
  }
}

// MARK: - Equatable for domain values the inputs carry

// The domain types below are value structs whose fields are all `Equatable`, but the
// domain files do not declare the conformance and stay untouched. These extensions
// live in Home-owned code and compare stored fields, nothing more. (Equatable
// synthesis is unavailable across files, so the comparisons are explicit.)

extension InventoryActiveItem: Equatable {
  static func == (lhs: InventoryActiveItem, rhs: InventoryActiveItem) -> Bool {
    lhs.ingredientId == rhs.ingredientId
      && lhs.ingredientName == rhs.ingredientName
      && lhs.storageLocation == rhs.storageLocation
      && lhs.totalRemainingGrams == rhs.totalRemainingGrams
      && lhs.averageConfidenceScore == rhs.averageConfidenceScore
      && lhs.earliestExpiresAt == rhs.earliestExpiresAt
      && lhs.daysUntilExpiry == rhs.daysUntilExpiry
      && lhs.lastUpdatedAt == rhs.lastUpdatedAt
      && lhs.lotCount == rhs.lotCount
      && lhs.mostRecentSource == rhs.mostRecentSource
      && lhs.hasEstimatedQuantity == rhs.hasEstimatedQuantity
  }
}

extension InventoryUseSoonSuggestion: Equatable {
  static func == (lhs: InventoryUseSoonSuggestion, rhs: InventoryUseSoonSuggestion) -> Bool {
    lhs.ingredientId == rhs.ingredientId
      && lhs.ingredientName == rhs.ingredientName
      && lhs.remainingGrams == rhs.remainingGrams
      && lhs.earliestExpiresAt == rhs.earliestExpiresAt
      && lhs.daysRemaining == rhs.daysRemaining
      && lhs.confidenceScore == rhs.confidenceScore
  }
}

extension MacroTotals: Equatable {
  static func == (lhs: MacroTotals, rhs: MacroTotals) -> Bool {
    lhs.calories == rhs.calories
      && lhs.protein == rhs.protein
      && lhs.carbs == rhs.carbs
      && lhs.fat == rhs.fat
  }
}

extension HealthProfile: Equatable {
  static func == (lhs: HealthProfile, rhs: HealthProfile) -> Bool {
    lhs.id == rhs.id
      && lhs.displayName == rhs.displayName
      && lhs.age == rhs.age
      && lhs.goal == rhs.goal
      && lhs.dailyCalories == rhs.dailyCalories
      && lhs.proteinPct == rhs.proteinPct
      && lhs.carbsPct == rhs.carbsPct
      && lhs.fatPct == rhs.fatPct
      && lhs.dietaryRestrictions == rhs.dietaryRestrictions
      && lhs.allergenIngredientIds == rhs.allergenIngredientIds
      && lhs.allergenSelectedGroups == rhs.allergenSelectedGroups
      && lhs.allergenPreferencesVersion == rhs.allergenPreferencesVersion
      && lhs.updatedAt == rhs.updatedAt
  }
}

extension HomeRecommendation: Equatable {
  static func == (lhs: HomeRecommendation, rhs: HomeRecommendation) -> Bool {
    lhs.recipeID == rhs.recipeID
      && lhs.recipeName == rhs.recipeName
      && lhs.explanation == rhs.explanation
      && lhs.cookTimeMinutes == rhs.cookTimeMinutes
      && lhs.matchLabel == rhs.matchLabel
      && lhs.badgeLabel == rhs.badgeLabel
      && lhs.ingredientIDs == rhs.ingredientIDs
  }
}

// MARK: - Fork projection (current view seam)

extension HomeFlowStateMap {
  /// The fork-level state for the Home view's gate: the same precedence rules as
  /// `state(inputs:cookContext:)` — error (owned by the nil-snapshot branch in the
  /// view) above cooking above returning above empty-new above partly-stocked —
  /// evaluated over the dashboard snapshot the sections already consume plus the
  /// view-supplied cook context.
  ///
  /// `stockedIngredientCount` carries the same quantity evidence as
  /// `inventoryItems` — distinct ingredients with active inventory quantity
  /// (remaining grams > 0) — so both paths resolve the same state. A populated
  /// recipe catalog with an empty pantry is empty-new, not partly-stocked.
  ///
  /// The canonical `HomeFlowInputs` path remains the redesigned Home's entry point;
  /// this projection exists so the shipped view can switch its fork on the map
  /// without re-plumbing the sections. It never reports `.error`: a non-nil
  /// snapshot means the read pass succeeded, and the view's existing
  /// nil-snapshot/loading/error branches keep owning that state. Tutorial
  /// progress is deliberately not an input — the view decides what an `.emptyNew`
  /// kitchen displays.
  ///
  static func state(
    from snapshot: HomeDashboardSnapshot,
    cookContext: HomeCookContext?
  ) -> HomeFlowState {
    if let cookContext {
      return .cooking(cookContext)
    }
    if !snapshot.hasOnboarded {
      return .emptyNew
    }
    if snapshot.totalMealsCooked >= 1 {
      return .returning
    }
    if snapshot.stockedIngredientCount > 0 {
      return .partlyStocked
    }
    return .emptyNew
  }
}
