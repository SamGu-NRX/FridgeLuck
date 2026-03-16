import SwiftUI

/// A drawer-style sheet for browsing a recipe's details before deciding to cook.
/// Covers ~92% of the screen. Shows hero visual, title, macros, health score,
/// ingredients, and a live-cook CTA. Does NOT show step-by-step instructions.
struct RecipePreviewDrawer: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let scoredRecipe: ScoredRecipe
  var onStartCooking: () -> Void

  @State private var ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)] = []
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
              ingredients: ingredients,
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
      .onPreferenceChange(SpotlightAnchorKey.self) { swapSpotlight.anchors = $0 }
      .onAppear {
        swapSpotlight.onScrollToAnchor = { anchorID in
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(AppMotion.spotlightMove) {
              scrollProxy.scrollTo(anchorID, anchor: .center)
            }
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      RecipePreviewBottomCTA(onStartCooking: onStartCooking)
    }
    .background(AppTheme.bg)
    .task {
      await loadIngredients()
      await loadExistingPhoto()
      await revealSections()
      if !hasSeenSwapTooltip {
        let hasAnySwap = ingredients.contains { item in
          deps.substitutionService.hasSubstitutions(for: item.ingredient.id ?? -1)
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
        swapSpotlight.activeSteps = nil
      }
    }
    .overlay {
      if showSwapSpotlight, let steps = swapSpotlight.activeSteps {
        SpotlightTutorialOverlay(
          steps: steps,
          anchors: swapSpotlight.anchors,
          isPresented: Binding(
            get: { showSwapSpotlight },
            set: { isPresented in
              if !isPresented {
                showSwapSpotlight = false
                swapSpotlight.activeSteps = nil
                hasSeenSwapTooltip = true
              }
            }
          ),
          onScrollToAnchor: swapSpotlight.onScrollToAnchor
        )
        .ignoresSafeArea()
      }
    }
  }

  // MARK: - Swap Spotlight

  private func presentSwapSpotlight() {
    guard !showSwapSpotlight else { return }
    swapSpotlight.activeSteps = SpotlightStep.swapIngredients
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
    guard let recipeId = recipe.id else { return }
    ingredients = (try? deps.recipeRepository.ingredientsForRecipe(id: recipeId)) ?? []
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
