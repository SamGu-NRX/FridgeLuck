import FLFeatureLogic
import SwiftUI

/// A drawer-style sheet for browsing a recipe's details before deciding to cook.
/// Covers ~92% of the screen. Shows hero visual, title, macros, health score,
/// ingredients, and the cooking CTAs. Does NOT show step-by-step instructions.
struct RecipePreviewDrawer: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let scoredRecipe: ScoredRecipe
  /// Receives the swaps chosen here so the cooking guide starts with them.
  var onStartCooking: ([Int64: (substitution: Substitution, ingredient: Ingredient)]) -> Void
  var onCookWithLeChef: () -> Void

  @State private var ingredientRows: [RecipePreviewIngredientRow] = []
  @State private var selectedIngredientForDetail: Ingredient?
  @State private var substitutionTarget: (ingredient: Ingredient, quantity: RecipeIngredient)?
  @State private var activeSubstitutions:
    [Int64: (substitution: Substitution, ingredient: Ingredient)] = [:]
  @State private var sectionsRevealed: Int = 0
  @State private var existingPhoto: UIImage?

  // MARK: - Swap Tooltip State
  @AppStorage(TutorialStorageKeys.hasSeenSwapTooltip) private var hasSeenSwapTooltip = false
  @State private var showSwapSpotlight = false
  @State private var swapSpotlight = SpotlightCoordinator()

  private var recipe: Recipe { scoredRecipe.recipe }
  private var macros: RecipeMacros { scoredRecipe.macros }
  private let totalSections = 5

  var body: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          RecipePreviewHeroSection(recipe: recipe, existingPhoto: existingPhoto)
            .opacity(sectionOpacity(0))
            .offset(y: sectionOffset(0))

          VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
            RecipePreviewTitleSection(recipe: recipe)
              .opacity(sectionOpacity(1))
              .offset(y: sectionOffset(1))

            RecipePreviewHealthSection(scoredRecipe: scoredRecipe)
              .opacity(sectionOpacity(2))
              .offset(y: sectionOffset(2))

            RecipePreviewMacroSection(macros: macros)
              .opacity(sectionOpacity(3))
              .offset(y: sectionOffset(3))

            RecipePreviewIngredientSection(
              rows: ingredientRows,
              scoredRecipe: scoredRecipe,
              activeSubstitutions: activeSubstitutions,
              hasSubstitutions: { ingredientID in
                deps.substitutionService.hasSubstitutions(for: ingredientID)
              },
              onIngredientSelected: { ingredient in
                selectedIngredientForDetail = ingredient
              },
              onSwapSelected: { ingredient, quantity in
                substitutionTarget = (ingredient, quantity)
              }
            )
            .opacity(sectionOpacity(4))
            .offset(y: sectionOffset(4))
          }
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.top, AppTheme.Space.lg)
          .padding(.bottom, AppTheme.Space.xxl)
        }
      }
      .onPreferenceChange(SpotlightAnchorKey.self) {
        swapSpotlight.updateAnchors($0)
      }
      .onAppear {
        swapSpotlight.scrollToAnchors(with: scrollProxy, reduceMotion: reduceMotion, after: 0.02)
      }
      .onChange(of: reduceMotion) { _, reduceMotion in
        swapSpotlight.scrollToAnchors(with: scrollProxy, reduceMotion: reduceMotion, after: 0.02)
      }
      .onDisappear {
        swapSpotlight.stopScrolling()
      }
    }
    .safeAreaInset(edge: .bottom) {
      RecipePreviewBottomCTA(
        uiTestFragment: scoredRecipe.id.uiTestFragment,
        onStartCooking: { onStartCooking(activeSubstitutions) },
        onCookWithLeChef: onCookWithLeChef
      )
    }
    .background(AppTheme.bg)
    .task {
      await loadIngredients()
      await loadExistingPhoto()
      await revealSections()
      if !hasSeenSwapTooltip {
        let hasAnySwap = ingredientRows.contains { row in
          guard let ingredientID = row.linked?.ingredient.id else { return false }
          return deps.substitutionService.hasSubstitutions(for: ingredientID)
        }
        if hasAnySwap {
          let delay = reduceMotion ? 0.2 : 0.6
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          guard !Task.isCancelled else { return }
          presentSwapSpotlight()
        }
      }
    }
    .sheet(item: $selectedIngredientForDetail) { ingredient in
      IngredientDetailSheet(ingredient: ingredient)
    }
    .sheet(
      item: Binding(
        get: {
          substitutionTarget.map {
            SubstitutionTargetWrapper(ingredient: $0.ingredient, quantity: $0.quantity)
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
          activeSubstitutions[target.ingredient.id ?? -1] = (substitution, subIngredient)
        }
        hasSeenSwapTooltip = true
        showSwapSpotlight = false
        swapSpotlight.activePresentation = nil
      }
    }
    .overlay {
      // Suppressed under the UI journey like the other spotlights: it lands over the
      // Start cooking button a moment after the drawer opens and swallows the tap.
      if showSwapSpotlight, !UITestJourney.isActive,
        let presentation = swapSpotlight.activePresentation {
        SpotlightTutorialOverlay(
          presentationID: presentation.id,
          steps: presentation.steps,
          anchors: swapSpotlight.anchors,
          isPresented: Binding(
            get: { showSwapSpotlight },
            set: { isPresented in
              if !isPresented {
                showSwapSpotlight = false
                swapSpotlight.activePresentation = nil
                hasSeenSwapTooltip = true
              }
            }
          ),
          onScrollToAnchor: swapSpotlight.onScrollToAnchor
        )
        .id(presentation.id)
        .ignoresSafeArea()
      }
    }
  }

  // MARK: - Swap Spotlight

  private func presentSwapSpotlight() {
    guard !showSwapSpotlight else { return }
    swapSpotlight.present(steps: SpotlightStep.swapIngredients, source: "swapIngredients")
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
      showSwapSpotlight = true
    }
  }

  // MARK: - Animation Helpers

  private func sectionOpacity(_ index: Int) -> Double {
    sectionsRevealed > index ? 1 : 0
  }

  private func sectionOffset(_ index: Int) -> CGFloat {
    sectionsRevealed > index ? 0 : 14
  }

  private func revealSections() async {
    guard !reduceMotion else {
      sectionsRevealed = totalSections
      return
    }

    for i in 0..<totalSections {
      try? await Task.sleep(for: .milliseconds(60))
      withAnimation(AppMotion.sectionReveal) {
        sectionsRevealed = i + 1
      }
    }
  }

  // MARK: - Data Loading

  private func loadIngredients() async {
    // Catalog entries carry no integer recipe id; their ingredient section comes from
    // the structured catalog packet — the same repository read the cooking guide and the
    // assistant context use. Every line shows, including lines no app ingredient stands
    // for, because the results card counts those as missing. Falls back to the legacy
    // instructions path when the packet is missing or empty.
    if let packet = try? deps.recipeRepository.catalogCookPacket(for: scoredRecipe),
      !packet.lines.isEmpty
    {
      let linkedIDs = Set(packet.lines.compactMap(\.bridgedIngredientId))
      let ingredientsByID = (try? deps.recipeRepository.ingredients(withIDs: linkedIDs)) ?? [:]
      ingredientRows = RecipePreviewIngredientRows.catalog(packet, ingredientsByID: ingredientsByID)
      return
    }

    guard let recipeId = recipe.id else { return }
    ingredientRows = RecipePreviewIngredientRows.legacy(
      (try? deps.recipeRepository.ingredientsForRecipe(id: recipeId)) ?? [])
  }

  private func loadExistingPhoto() async {
    guard let recipeId = recipe.id else { return }
    if let path = try? deps.userDataRepository.latestPhotoPath(forRecipeId: recipeId) {
      existingPhoto = deps.imageStorageService.load(relativePath: path)
    }
  }
}

// MARK: - Substitution Target Wrapper

/// Identifiable wrapper so `.sheet(item:)` works with our tuple.
private struct SubstitutionTargetWrapper: Identifiable {
  let ingredient: Ingredient
  let quantity: RecipeIngredient
  var id: Int64 { ingredient.id ?? -1 }
}
