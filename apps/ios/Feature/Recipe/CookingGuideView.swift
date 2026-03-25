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
  private let scopedDependencies: Dependencies?
  var onComplete: () -> Void

  struct Dependencies {
    let ingredientsForRecipe:
      (Int64) throws -> [(ingredient: Ingredient, quantity: RecipeIngredient)]
    let hasSubstitutions: (Int64) -> Bool
  }

  init(
    scoredRecipe: ScoredRecipe,
    dependencies: Dependencies? = nil,
    onComplete: @escaping () -> Void
  ) {
    self.scoredRecipe = scoredRecipe
    self.scopedDependencies = dependencies
    self.onComplete = onComplete
  }

  @State private var currentPage: Int = 0
  @State private var ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)] = []
  @State private var checkedIngredients: Set<Int64> = []
  @State private var completedSteps: Set<Int> = []
  @State private var showCelebration = false
  @State private var pageDirection: PageDirection = .forward
  @State private var pageAppeared = false
  @State private var substitutionTarget: (ingredient: Ingredient, quantity: RecipeIngredient)?
  @State private var activeSubstitutions:
    [Int64: (substitution: Substitution, ingredient: Ingredient)] = [:]

  private var recipe: Recipe { scoredRecipe.recipe }

  private var instructionSteps: [String] {
    recipe.instructions
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
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
            withAnimation(reduceMotion ? nil : AppMotion.celebration) {
              showCelebration = true
            }
          }
        )
      }

      if showCelebration {
        CookingCelebrationView(
          scoredRecipe: scoredRecipe,
          onDismiss: {
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
          completedSteps: $completedSteps,
          pageAppeared: pageAppeared,
          reduceMotion: reduceMotion,
          contentHorizontalPadding: contentHorizontalPadding
        )
      }
    }
  }

  private func goToNextPage() {
    guard currentPage < totalPages - 1 else { return }
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
