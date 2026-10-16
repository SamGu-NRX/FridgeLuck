import FLFeatureLogic
import SwiftUI

/// A paginated cooking guide experience. Each cooking step gets its own full page.
/// Page 0 is the ingredients checklist, pages 1-N are individual steps,
/// and the final action triggers the "I Made This" celebration.
struct CookingGuideView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let scoredRecipe: ScoredRecipe
  let logsMeal: Bool
  private let guide: CookingGuideSteps
  private let scopedDependencies: Dependencies?
  var onComplete: () -> Void

  struct Dependencies {
    let ingredientsForRecipe:
      (Int64) throws -> [(ingredient: Ingredient, quantity: RecipeIngredient)]
    let hasSubstitutions: (Int64) -> Bool
  }

  init(
    scoredRecipe: ScoredRecipe,
    logsMeal: Bool,
    initialSubstitutions: [Int64: (substitution: Substitution, ingredient: Ingredient)] = [:],
    dependencies: Dependencies? = nil,
    onComplete: @escaping () -> Void
  ) {
    self.scoredRecipe = scoredRecipe
    self.logsMeal = logsMeal
    self.guide = CookingGuideSteps(instructions: scoredRecipe.recipe.instructions)
    self._activeSubstitutions = State(initialValue: initialSubstitutions)
    self.scopedDependencies = dependencies
    self.onComplete = onComplete
  }

  @State private var currentPage: Int = 0
  /// Structured guide steps for a catalog entry, loaded with the ingredients; the init-time
  /// `guide` stays empty for catalog recipes because their content lives in the packet.
  @State private var catalogGuide: CookingGuideSteps?
  @State private var ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)] = []
  @State private var checkedIngredients: Set<Int64> = []
  @State private var completedSteps: Set<Int> = []
  @State private var showCelebration = false
  @State private var pageDirection: PageDirection = .forward
  @State private var pageAppeared = false
  @State private var substitutionTarget: (ingredient: Ingredient, quantity: RecipeIngredient)?
  @State private var activeSubstitutions:
    [Int64: (substitution: Substitution, ingredient: Ingredient)] = [:]
  /// The LeChef cook session (SPEC §4) — started or resumed on first appearance, and kept in
  /// step with page turns so progress survives a relaunch (LeChef §11). Nil only before the
  /// task runs. Meal logging stays with the celebration path; the session never double-logs.
  @State private var cook: CookModeViewModel?

  private var recipe: Recipe { scoredRecipe.recipe }
  /// The catalog content this recipe cooks from, when it is a catalog recipe: structured
  /// steps from the installed bundle-v2 revision, so the session runs the packet's timers
  /// and safety checks and the meal links to the exact revision that was cooked. nil keeps
  /// the legacy parsed-instructions path.
  private var catalogContent: CatalogCookContent? {
    CookingGuideView.makeCatalogContent(for: scoredRecipe, in: deps.recipeRepository)
  }

  /// Resolves the catalog content a guide cooks from for this scored result. A bridged
  /// legacy recipe resolves through `recipes_catalog.legacy_recipe_id`; a catalog-native
  /// result — the recommend pool builds `Recipe(id: nil, …)` and carries the identity in
  /// its own match's catalog ref — resolves through that ref. Unsaved drafts (no integer
  /// id, no catalog match) and recipes whose packet cannot load stay on the legacy
  /// parsed-instructions path. Extracted so tests exercise the exact production gate.
  static func makeCatalogContent(
    for scoredRecipe: ScoredRecipe, in repository: RecipeRepository
  ) -> CatalogCookContent? {
    let catalogId: String?
    if let legacyId = scoredRecipe.recipe.id {
      catalogId = try? repository.catalogRecipeID(forLegacyRecipeID: legacyId)
    } else {
      catalogId = scoredRecipe.catalog?.ref.id
    }
    // Unscreened by design: the id comes from a scored result, and every `ScoredRecipe` comes
    // out of the recommendation search, which already admitted it for the household.
    guard let catalogId, let packet = try? repository.unscreenedCatalog.cookPacket(catalogId: catalogId)
    else { return nil }
    return CatalogCookContent(
      catalogId: packet.catalogId,
      revision: packet.revision,
      steps: packet.steps)
  }

  /// Substitutions of required ingredients, in the form the meal log records. Optional
  /// ingredients never count toward logged nutrition or consumption, so their swaps aren't saved.
  private var swaps: [IngredientSwap] {
    let requiredIDs = Set(ingredients.filter(\.quantity.isRequired).map(\.quantity.ingredientId))
    return activeSubstitutions.compactMap { originalId, chosen in
      guard requiredIDs.contains(originalId) else { return nil }
      return IngredientSwap(
        originalIngredientId: originalId,
        substituteIngredientId: chosen.substitution.substituteId,
        ratio: chosen.substitution.ratio
      )
    }
    .sorted { $0.originalIngredientId < $1.originalIngredientId }
  }

  private var instructionSteps: [String] {
    if let catalogGuide, !catalogGuide.steps.isEmpty { return catalogGuide.steps }
    return guide.steps
  }

  private var totalPages: Int { 1 + instructionSteps.count }
  private var totalSteps: Int { instructionSteps.count }
  private var isOnIngredientsPage: Bool { currentPage == 0 }
  private var isOnLastStep: Bool { currentPage == totalPages - 1 }
  private var currentStepIndex: Int { currentPage - 1 }
  private var contentHorizontalPadding: CGFloat { AppTheme.Space.page }
  private var dependencies: Dependencies {
    if let scopedDependencies { return scopedDependencies }
    return Dependencies(
      ingredientsForRecipe: { recipeID in
        try deps.recipeRepository.ingredientsForRecipe(id: recipeID)
      },
      hasSubstitutions: { ingredientID in
        deps.substitutionService.hasSubstitutions(for: ingredientID)
      }
    )
  }

  private var topBarCounterText: String {
    guard totalSteps > 0 else { return "0/0" }
    if isOnIngredientsPage { return "Prep" }
    return "\(currentStepIndex + 1)/\(totalSteps)"
  }

  private var progress: Double {
    guard totalSteps > 0 else { return 0 }
    return min(max(Double(currentPage) / Double(totalSteps), 0), 1)
  }

  var body: some View {
    ZStack {
      AppTheme.bg.ignoresSafeArea()

      VStack(spacing: 0) {
        CookingGuideTopBar(
          recipeTitle: recipe.title,
          counterText: topBarCounterText,
          progress: progress,
          contentHorizontalPadding: contentHorizontalPadding,
          reduceMotion: reduceMotion,
          onClose: { dismiss() }
        )

        pageContent
          .id(currentPage)
          .transition(pageTransition)
          .animation(reduceMotion ? nil : AppMotion.pageTurn, value: currentPage)

        Spacer(minLength: 0)

        CookingGuideBottomNavigation(
          currentPage: currentPage,
          isOnLastStep: isOnLastStep,
          contentHorizontalPadding: contentHorizontalPadding,
          onBack: goToPreviousPage,
          onNext: goToNextPage,
          onComplete: {
            // The celebration is the remember phase — the session completes when it starts,
            // so closing the app here still ends cooking (LeChef §4.2).
            cook?.complete()
            withAnimation(reduceMotion ? nil : AppMotion.celebration) {
              showCelebration = true
            }
          }
        )
      }

      if showCelebration {
        CookingCelebrationView(
          scoredRecipe: scoredRecipe,
          logsMeal: logsMeal,
          swaps: swaps,
          catalogId: catalogContent?.catalogId,
          catalogRevision: catalogContent?.revision,
          onDismiss: {
            // Terminalize the remember phase: skipped remember entry, row persisted.
            cook?.skipRemember()
            dismiss()
            onComplete()
          }
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .zIndex(10)
      }
    }
    .task {
      await loadIngredients()
      await startOrResumeSession()
      if !reduceMotion {
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(AppMotion.sectionReveal) {
          pageAppeared = true
        }
      } else {
        pageAppeared = true
      }
    }
    .sheet(
      item: Binding(
        get: {
          substitutionTarget.map {
            BookSubstitutionTarget(ingredient: $0.ingredient, quantity: $0.quantity)
          }
        },
        set: { wrapper in substitutionTarget = wrapper.map { ($0.ingredient, $0.quantity) } }
      )
    ) { target in
      SubstitutionSheet(
        ingredient: target.ingredient,
        quantityGrams: target.quantity.quantityGrams,
        displayQuantity: target.quantity.displayQuantity
      ) { substitution, subIngredient in
        withAnimation(reduceMotion ? nil : AppMotion.cardSpring) {
          let slot = CookingGuideStateTransitions.substitutionSlot(for: target.ingredient.id)
          activeSubstitutions[slot] = (substitution, subIngredient)
        }
      }
    }
  }

  @ViewBuilder
  private var pageContent: some View {
    ScrollView {
      if isOnIngredientsPage {
        CookingGuideIngredientsPage(
          ingredients: ingredients,
          checkedIngredients: $checkedIngredients,
          activeSubstitutions: $activeSubstitutions,
          hasSubstitution: dependencies.hasSubstitutions,
          onRequestSubstitution: { ingredient, quantity in
            substitutionTarget = (ingredient, quantity)
          },
          pageAppeared: pageAppeared,
          reduceMotion: reduceMotion,
          contentHorizontalPadding: contentHorizontalPadding
        )
      } else if currentStepIndex >= 0, currentStepIndex < instructionSteps.count {
        CookingGuideStepPage(
          index: currentStepIndex,
          totalSteps: totalSteps,
          step: instructionSteps[currentStepIndex],
          attribution: isOnLastStep ? guide.attribution : nil,
          completedSteps: $completedSteps,
          suggestedTimerSeconds: cook?.suggestedTimerSeconds,
          onStartTimer: { cook?.startSuggestedTimer() },
          pageAppeared: pageAppeared,
          reduceMotion: reduceMotion,
          contentHorizontalPadding: contentHorizontalPadding
        )
      }
    }
  }

  /// Starts or resumes the cook session and mirrors the persisted step onto the pager once —
  /// a relaunch lands on the step the cook was on (LeChef §4.2, §11).
  private func startOrResumeSession() async {
    guard cook == nil else { return }
    let store = CookSessionStore(db: deps.appDatabase.dbQueue)
    let sessionVM = CookModeViewModel(
      recipe: recipe,
      logsMeal: false,
      dependencies: .init(
        store: store,
        substitutionOptions: { deps.substitutionService.substitutions(for: $0) },
        // Composition facts ship per canonical key (v2 table), so the re-check
        // resolves the substitute through the identity bridge and screens the
        // household's active restrictions; unknown still blocks (LeChef §7).
        substituteIsAllergen: { deps.substitutionService.substituteIsAllergen(for: $0) },
        logMeal: { _, _, _, _ in },
        scaleLines: { [] },
        now: Date.init,
        newID: { UUID().uuidString.lowercased() },
        scheduler: CookTimerNotificationScheduler()),
      catalog: catalogContent)
    sessionVM.startOrResume()
    if sessionVM.session.phase == .cooking, sessionVM.session.currentStep > 0,
      sessionVM.session.currentStep < totalSteps
    {
      pageDirection = .forward
      currentPage = sessionVM.session.currentStep + 1
    }
    cook = sessionVM
  }

  private func goToNextPage() {
    guard currentPage < totalPages - 1 else { return }
    if currentPage >= 1 { cook?.advance() }
    pageDirection = .forward
    pageAppeared = false
    withAnimation(reduceMotion ? nil : AppMotion.pageTurn) {
      currentPage += 1
    }
    Task {
      try? await Task.sleep(for: .milliseconds(50))
      withAnimation(reduceMotion ? nil : AppMotion.sectionReveal) {
        pageAppeared = true
      }
    }
  }

  private func goToPreviousPage() {
    guard currentPage > 0 else { return }
    if currentPage >= 2 { cook?.back() }
    pageDirection = .backward
    pageAppeared = false
    withAnimation(reduceMotion ? nil : AppMotion.pageTurn) {
      currentPage -= 1
    }
    Task {
      try? await Task.sleep(for: .milliseconds(50))
      withAnimation(reduceMotion ? nil : AppMotion.sectionReveal) {
        pageAppeared = true
      }
    }
  }

  private var pageTransition: AnyTransition {
    switch pageDirection {
    case .forward:
      return .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      )
    case .backward:
      return .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity),
        removal: .move(edge: .trailing).combined(with: .opacity)
      )
    }
  }

  private func loadIngredients() async {
    // Catalog entries carry no integer recipe id; their guide steps and ingredient
    // section come from the structured catalog packet — the same repository path the
    // preview drawer and the assistant context use — so all surfaces agree. Falls back
    // to the legacy path for legacy recipes.
    if let packet = try? deps.recipeRepository.catalogCookPacket(for: scoredRecipe),
      !packet.steps.isEmpty
    {
      catalogGuide = CookingGuideSteps(
        instructions: packet.steps.map(\.text).joined(separator: "\n"))
      ingredients = (try? deps.recipeRepository.cookPacketIngredients(packet)) ?? []
      return
    }
    guard let recipeId = recipe.id else { return }
    ingredients = (try? dependencies.ingredientsForRecipe(recipeId)) ?? []
  }
}

private enum PageDirection {
  case forward
  case backward
}

private struct BookSubstitutionTarget: Identifiable {
  let ingredient: Ingredient
  let quantity: RecipeIngredient
  var id: Int64 { ingredient.id ?? -1 }
}
