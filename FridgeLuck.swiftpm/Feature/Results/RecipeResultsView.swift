import SwiftUI
import UIKit

/// Shows recipe recommendations based on the user's available ingredients.
/// Tapping a recipe opens a preview drawer (sheet), which leads to the recipe book
/// (fullScreenCover), then the cooking celebration, and finally dismisses back to Home
/// via the NavigationCoordinator.
struct RecipeResultsView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(NavigationCoordinator.self) private var navCoordinator
  @Environment(LiveAssistantCoordinator.self) private var liveAssistantCoordinator
  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""
  let ingredientIds: Set<Int64>
  let ingredientNames: [String]
  let fridgePhoto: UIImage?
  let scanConfidenceScore: Double?

  @StateObject private var engine: RecommendationEngine
  @Namespace private var transitionNamespace
  @State private var revealedCount: Int = 0

  @State private var selectedRecipe: ScoredRecipe?
  @State private var cookingRecipe: ScoredRecipe?
  @State private var didPromoteRecipeMatchLesson = false

  init(
    ingredientIds: Set<Int64>,
    ingredientNames: [String] = [],
    fridgePhoto: UIImage? = nil,
    scanConfidenceScore: Double? = nil,
    engine: RecommendationEngine
  ) {
    self.ingredientIds = ingredientIds
    self.ingredientNames = ingredientNames
    self.fridgePhoto = fridgePhoto
    self.scanConfidenceScore = scanConfidenceScore
    _engine = StateObject(wrappedValue: engine)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        contextHeader
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.bottom, AppTheme.Space.lg)

        if let generated = engine.aiGeneratedRecipe {
          aiGeneratedRecipeCard(generated)
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)
        }

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
      if !ingredientNames.isEmpty {
        await engine.generateAIRecipe(
          ingredientNames: ingredientNames,
          photoJPEGData: fridgePhoto?.jpegData(compressionQuality: 0.72),
          scanConfidenceScore: scanConfidenceScore
        )
      }
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

  private var tutorialProgress: TutorialProgress {
    TutorialProgress(storageString: tutorialStorageString)
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

  private func aiGeneratedRecipeCard(_ generated: GeneratedRecipeResult) -> some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack {
          FLSectionHeader(
            "Live Recipe Idea",
            subtitle: generated.isAIGenerated
              ? "Photo-grounded ingredient synthesis" : "Local fallback suggestion",
            icon: "wand.and.sparkles"
          )
          Spacer()
          FLStatusPill(
            text: generated.isAIGenerated ? "AI" : "Fallback",
            kind: generated.isAIGenerated ? .positive : .neutral
          )
        }

        Text(generated.title)
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        Text(
          "\(generated.timeMinutes) min · \(generated.servings) servings · ~\(generated.estimatedCaloriesPerServing) kcal/serving"
        )
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)
      }
    }
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
      onTap: { handleRecipeSelection(scored) }
    )
  }

  // MARK: - Staggered Two-Column Grid

  private var allResultsGrid: some View {
    RecipeResultsExactGridSection(
      exactMatches: engine.sections.exact,
      revealedCount: revealedCount,
      reduceMotion: reduceMotion,
      transitionNamespace: transitionNamespace,
      onTap: handleRecipeSelection
    )
  }

  private var nearMatchSection: some View {
    RecipeResultsNearMatchSection(
      nearMatches: engine.sections.nearMatch,
      onTap: handleRecipeSelection
    )
  }

  private func handleRecipeSelection(_ scored: ScoredRecipe) {
    guard tutorialProgress.currentQuest == .pickRecipeMatch, !didPromoteRecipeMatchLesson else {
      selectedRecipe = scored
      return
    }

    let ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)]
    if let recipeID = scored.recipe.id {
      ingredients = (try? deps.recipeRepository.ingredientsForRecipe(id: recipeID)) ?? []
    } else {
      ingredients = []
    }

    let recipeContext = LiveAssistantRecipeContext(
      scoredRecipe: scored,
      ingredients: ingredients
    )
    liveAssistantCoordinator.storeRecipeMatch(
      scoredRecipe: scored,
      context: recipeContext
    )

    didPromoteRecipeMatchLesson = true
    var progress = tutorialProgress
    progress.markCompleted(.pickRecipeMatch)
    tutorialStorageString = progress.storageString
    navCoordinator.returnHome()
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
