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
  @Environment(TutorialFlowContext.self) private var tutorialFlowContext: TutorialFlowContext?
  let ingredientIds: Set<Int64>
  let ingredientNames: [String]
  let fridgePhoto: UIImage?
  let scanConfidenceScore: Double?
  let preferredRecipeID: Int64?

  @State private var replaySpotlightPending: Bool
  @StateObject private var engine: RecommendationEngine
  @Namespace private var transitionNamespace
  @State private var revealedCount: Int = 0

  @State private var selectedRecipe: ScoredRecipe?
  @State private var didPromoteRecipeMatchLesson = false
  @State private var didPresentPreferredRecipe = false
  @State private var recipeMatchSpotlight = SpotlightCoordinator()
  @State private var showRecipeMatchSpotlight = false

  init(
    ingredientIds: Set<Int64>,
    ingredientNames: [String] = [],
    fridgePhoto: UIImage? = nil,
    scanConfidenceScore: Double? = nil,
    preferredRecipeID: Int64? = nil,
    engine: RecommendationEngine,
    replaySpotlightOnAppear: Bool = false
  ) {
    self.ingredientIds = ingredientIds
    self.ingredientNames = ingredientNames
    self.fridgePhoto = fridgePhoto
    self.scanConfidenceScore = scanConfidenceScore
    self.preferredRecipeID = preferredRecipeID
    _replaySpotlightPending = State(initialValue: replaySpotlightOnAppear)
    _engine = StateObject(wrappedValue: engine)
  }

  var body: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          contextHeader
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.bottom, AppTheme.Space.lg)
            .id("recipeResultsSummary")
            .spotlightAnchor("recipeResultsSummary")

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
                .id("recipeResultsBestMatch")
                .spotlightAnchor("recipeResultsBestMatch")
            }

            FLWaveDivider()
              .padding(.horizontal, AppTheme.Space.page)
              .padding(.bottom, AppTheme.Space.lg)

            VStack(alignment: .leading, spacing: 0) {
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
            .id("recipeResultsList")
            .spotlightAnchor("recipeResultsList")
          }
        }
        .onAppear {
          recipeMatchSpotlight.onScrollToAnchor = { anchorID in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
              withAnimation(AppMotion.spotlightMove) {
                scrollProxy.scrollTo(anchorID, anchor: .center)
              }
            }
          }
        }
      }
      .onPreferenceChange(SpotlightAnchorKey.self) {
        recipeMatchSpotlight.updateAnchors($0, retainingExistingValues: true)
      }
      .overlay {
        if showRecipeMatchSpotlight, let presentation = recipeMatchSpotlight.activePresentation {
          SpotlightTutorialOverlay(
            presentationID: presentation.id,
            steps: presentation.steps,
            anchors: recipeMatchSpotlight.anchors,
            isPresented: Binding(
              get: { showRecipeMatchSpotlight },
              set: { isPresented in
                if !isPresented {
                  showRecipeMatchSpotlight = false
                  recipeMatchSpotlight.activePresentation = nil
                }
              }
            ),
            onScrollToAnchor: recipeMatchSpotlight.onScrollToAnchor
          )
          .id(presentation.id)
          .ignoresSafeArea()
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
      autoPresentPreferredRecipeIfNeeded()
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
      autoPresentPreferredRecipeIfNeeded()
      Task { await revealRecommendationsIfNeeded() }
    }
    .onChange(of: engine.sections.nearMatch.count) { _, _ in
      autoPresentPreferredRecipeIfNeeded()
    }
    .task(id: shouldPresentReplayRecipeMatchSpotlight) {
      guard shouldPresentReplayRecipeMatchSpotlight else { return }
      let delay = reduceMotion ? 0.3 : 0.8
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      guard shouldPresentReplayRecipeMatchSpotlight else { return }
      presentReplayRecipeMatchSpotlight()
    }
    .sheet(item: $selectedRecipe) { recipe in
      RecipePreviewDrawer(scoredRecipe: recipe) {
        handleStartCooking(recipe)
      }
      .presentationDetents([.fraction(0.92)])
      .presentationDragIndicator(.visible)
      .presentationCornerRadius(AppTheme.Radius.xl)
    }
  }

  private var shouldPresentReplayRecipeMatchSpotlight: Bool {
    guard replaySpotlightPending else { return false }
    guard recipeMatchSpotlight.activePresentation == nil else { return false }
    guard !showRecipeMatchSpotlight else { return false }
    return isRecipeMatchAnchorReady("recipeResultsSummary")
      && isRecipeMatchAnchorReady("recipeResultsBestMatch")
      && isRecipeMatchAnchorReady("recipeResultsList")
  }

  private func isRecipeMatchAnchorReady(_ anchorID: String) -> Bool {
    guard let rect = recipeMatchSpotlight.anchors[anchorID] else { return false }
    guard !rect.isEmpty, !rect.isNull, !rect.isInfinite else { return false }
    guard rect.width > 0, rect.height > 0 else { return false }
    return rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
  }

  private func presentReplayRecipeMatchSpotlight() {
    guard recipeMatchSpotlight.activePresentation == nil else { return }
    recipeMatchSpotlight.present(
      steps: SpotlightStep.recipeMatchReplay,
      source: "recipeMatchReplay"
    )
    showRecipeMatchSpotlight = true
    replaySpotlightPending = false
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
    if let context = tutorialFlowContext,
      context.activeQuest == .pickRecipeMatch,
      !didPromoteRecipeMatchLesson
    {
      storeRecipeForAssistant(scored)
      didPromoteRecipeMatchLesson = true
      context.completeObjective()
      return
    }

    selectedRecipe = scored
  }

  private func handleStartCooking(_ scored: ScoredRecipe) {
    storeRecipeForAssistant(scored)
    selectedRecipe = nil
    Task {
      try? await Task.sleep(for: .milliseconds(220))
      navCoordinator.returnHome()
    }
  }

  private func storeRecipeForAssistant(_ scored: ScoredRecipe) {
    let ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)]
    if let recipeID = scored.recipe.id {
      ingredients = (try? deps.recipeRepository.ingredientsForRecipe(id: recipeID)) ?? []
    } else {
      ingredients = []
    }

    liveAssistantCoordinator.storeRecipeMatch(
      scoredRecipe: scored,
      context: LiveAssistantRecipeContext(scoredRecipe: scored, ingredients: ingredients)
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

  private func autoPresentPreferredRecipeIfNeeded() {
    guard
      let preferredRecipeID,
      !didPresentPreferredRecipe,
      let preferredRecipe = engine.recommendations.first(where: {
        $0.recipe.id == preferredRecipeID
      })
    else {
      return
    }

    didPresentPreferredRecipe = true
    selectedRecipe = preferredRecipe
  }
}
