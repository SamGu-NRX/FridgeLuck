import SwiftUI

/// Shows recipe recommendations based on the user's available ingredients.
/// Tapping a recipe opens a preview drawer (sheet), which leads to the recipe book
/// (fullScreenCover), then the cooking celebration, and finally dismisses back to Home
/// via the NavigationCoordinator.
struct RecipeResultsView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss
  @Environment(NavigationCoordinator.self) private var navCoordinator
  let ingredientIds: Set<Int64>

  @StateObject private var engine: RecommendationEngine
  @Namespace private var transitionNamespace
  @State private var revealedCount: Int = 0

  @State private var selectedRecipe: ScoredRecipe?
  @State private var cookingRecipe: ScoredRecipe?

  init(
    ingredientIds: Set<Int64>,
    engine: RecommendationEngine
  ) {
    self.ingredientIds = ingredientIds
    _engine = StateObject(wrappedValue: engine)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        contextHeader
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.lg)

        if engine.isLoading {
          loadingView
            .padding(.horizontal, AppTheme.Space.page)
        } else if engine.recommendations.isEmpty {
          emptyView
            .padding(.horizontal, AppTheme.Space.page)
        } else {
          if let pick = engine.quickSuggestion {
            bestMatchHero(pick)
              .padding(.bottom, AppTheme.Space.sectionBreak)
          }

          FLWaveDivider()
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)

          if !engine.sections.exact.isEmpty {
            allResultsGrid
              .padding(.horizontal, AppTheme.Space.page)
              .padding(.bottom, AppTheme.Space.lg)
          }

          if !engine.sections.nearMatch.isEmpty {
            nearMatchSection
              .padding(.horizontal, AppTheme.Space.page)
          }
        }
      }
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.bottomClearance)
    }
    .navigationTitle("Recipes")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .task {
      await engine.findRecipes(for: ingredientIds)
      await revealRecommendationsIfNeeded()
    }
    .onChange(of: engine.sections.exact.count) { _, _ in
      Task { await revealRecommendationsIfNeeded() }
    }
    .sheet(item: $selectedRecipe) { recipe in
      RecipePreviewDrawer(scoredRecipe: recipe) {
        selectedRecipe = nil
        Task {
          try? await Task.sleep(for: .milliseconds(350))
          cookingRecipe = recipe
        }
      }
      .presentationDetents([.fraction(0.92)])
      .presentationDragIndicator(.visible)
      .presentationCornerRadius(AppTheme.Radius.xl)
    }
    .fullScreenCover(item: $cookingRecipe) { recipe in
      CookingGuideView(scoredRecipe: recipe) {
        cookingRecipe = nil
        Task {
          try? await Task.sleep(for: .milliseconds(450))
          navCoordinator.returnHomeAfterCooking()
        }
      }
    }
  }

  // MARK: - Context Header (card-free)

  private var contextHeader: some View {
    RecipeResultsContextHeader(
      ingredientCount: ingredientIds.count,
      policySummary: engine.explanationPayload.policySummary,
      activeDietaryBadges: engine.explanationPayload.activeDietaryBadges,
      exactCount: engine.sections.exact.count,
      nearCount: engine.sections.nearMatch.count,
      quickSuggestionMinutes: engine.quickSuggestion?.recipe.timeMinutes,
      aiNotice: engine.aiEnhancementNotice
    )
  }

  // MARK: - Loading

  private var loadingView: some View {
    RecipeResultsLoadingView()
  }

  // MARK: - Empty

  private var emptyView: some View {
    FLEmptyState(
      title: "No recipe matches yet",
      message: engine.error?.localizedDescription
        ?? "Try confirming a few more ingredients or run another scan.",
      systemImage: "tray.fill",
      actionTitle: "Retry Search",
      action: {
        Task { await engine.findRecipes(for: ingredientIds) }
      }
    )
  }

  // MARK: - Best Match Hero (torn-edge, editorial)

  private func bestMatchHero(_ scored: ScoredRecipe) -> some View {
    RecipeResultsBestMatchHero(
      scored: scored,
      transitionNamespace: transitionNamespace,
      onTap: { selectedRecipe = scored }
    )
  }

  // MARK: - Staggered Two-Column Grid

  private var allResultsGrid: some View {
    RecipeResultsExactGridSection(
      exactMatches: engine.sections.exact,
      revealedCount: revealedCount,
      reduceMotion: reduceMotion,
      transitionNamespace: transitionNamespace,
      onTap: { selectedRecipe = $0 }
    )
  }

  private var nearMatchSection: some View {
    RecipeResultsNearMatchSection(
      nearMatches: engine.sections.nearMatch,
      onTap: { selectedRecipe = $0 }
    )
  }

  private func revealRecommendationsIfNeeded() async {
    let total = engine.sections.exact.count
    guard total > 0 else {
      revealedCount = 0
      return
    }

    if reduceMotion {
      revealedCount = total
      return
    }

    revealedCount = 0
    for index in 0..<total {
      try? await Task.sleep(for: .milliseconds(35))
      withAnimation(AppMotion.quick) {
        revealedCount = index
      }
    }
  }
}
