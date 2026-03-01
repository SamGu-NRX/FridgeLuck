import SwiftUI

/// A drawer-style sheet for browsing a recipe's details before deciding to cook.
/// Covers ~92% of the screen. Shows hero visual, title, macros, health score,
/// ingredients, and a "Start Cooking" CTA. Does NOT show step-by-step instructions.
struct RecipePreviewDrawer: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let scoredRecipe: ScoredRecipe
  var onStartCooking: () -> Void

  @State private var ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)] = []
  @State private var selectedIngredientForDetail: Ingredient?
  @State private var sectionsRevealed: Int = 0
  @State private var existingPhoto: UIImage?

  private var recipe: Recipe { scoredRecipe.recipe }
  private var macros: RecipeMacros { scoredRecipe.macros }
  private let totalSections = 5

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        heroVisual
          .opacity(sectionOpacity(0))
          .offset(y: sectionOffset(0))

        VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
          titleSection
            .opacity(sectionOpacity(1))
            .offset(y: sectionOffset(1))

          healthSection
            .opacity(sectionOpacity(2))
            .offset(y: sectionOffset(2))

          macroSection
            .opacity(sectionOpacity(3))
            .offset(y: sectionOffset(3))

          ingredientSection
            .opacity(sectionOpacity(4))
            .offset(y: sectionOffset(4))
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.top, AppTheme.Space.lg)
        .padding(.bottom, AppTheme.Space.xxl)
      }
    }
    .safeAreaInset(edge: .bottom) {
      bottomCTA
    }
    .background(AppTheme.bg)
    .task {
      await loadIngredients()
      await loadExistingPhoto()
      await revealSections()
    }
    .sheet(item: $selectedIngredientForDetail) { ingredient in
      IngredientDetailSheet(ingredient: ingredient)
    }
  }

  // MARK: - Hero Visual

  private var heroVisual: some View {
    ZStack {
      // Warm gradient derived from recipe tags
      heroGradient
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 0))

      if let photo = existingPhoto {
        // Show existing meal photo
        Image(uiImage: photo)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(height: 240)
          .clipped()
          .overlay {
            LinearGradient(
              colors: [.clear, AppTheme.bg.opacity(0.7)],
              startPoint: .center,
              endPoint: .bottom
            )
          }
      } else {
        // Placeholder with camera hint
        VStack(spacing: AppTheme.Space.sm) {
          ZStack {
            // Decorative organic blob
            FLOrganicBlob(seed: recipe.title.hashValue)
              .fill(AppTheme.surface.opacity(0.15))
              .frame(width: 100, height: 100)

            Image(systemName: "camera.fill")
              .font(.system(size: 28))
              .foregroundStyle(.white.opacity(0.7))
          }

          Text("Photo added after cooking")
            .font(AppTheme.Typography.label)
            .foregroundStyle(.white.opacity(0.6))
        }
      }
    }
  }

  private var heroGradient: some View {
    let tags = recipe.recipeTags

    // Pick gradient colors based on recipe's cuisine/type tags
    let (primary, secondary): (Color, Color) = {
      if tags.contains(.asian) { return (AppTheme.sage, AppTheme.deepOliveLight) }
      if tags.contains(.mediterranean) { return (AppTheme.oat, AppTheme.accent.opacity(0.7)) }
      if tags.contains(.mexican) { return (AppTheme.accent, AppTheme.accentLight) }
      if tags.contains(.breakfast) { return (AppTheme.heroLight, AppTheme.oat) }
      if tags.contains(.comfort) { return (AppTheme.dustyRose, AppTheme.accentLight) }
      if tags.contains(.vegetarian) || tags.contains(.vegan) {
        return (AppTheme.sage, AppTheme.sageLight)
      }
      // Default warm editorial
      return (AppTheme.bgDeep, AppTheme.oat.opacity(0.6))
    }()

    return LinearGradient(
      colors: [primary, secondary],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Title

  private var titleSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
          Text(recipe.title)
            .font(AppTheme.Typography.displayMedium)
            .foregroundStyle(AppTheme.textPrimary)

          HStack(spacing: AppTheme.Space.md) {
            Label("\(recipe.timeMinutes) min", systemImage: "clock")
            Label(
              "\(recipe.servings) serving\(recipe.servings > 1 ? "s" : "")",
              systemImage: "person.2"
            )
          }
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        if recipe.source == .aiGenerated {
          FLStatusPill(text: "AI", kind: .neutral)
        }
      }

      if !recipe.recipeTags.labels.isEmpty {
        FlowLayout(spacing: AppTheme.Space.xs) {
          ForEach(recipe.recipeTags.labels, id: \.self) { tag in
            Text(tag.replacingOccurrences(of: "_", with: " "))
              .font(AppTheme.Typography.labelSmall)
              .padding(.horizontal, AppTheme.Space.sm)
              .padding(.vertical, AppTheme.Space.chipVertical)
              .background(AppTheme.surfaceMuted, in: Capsule())
              .foregroundStyle(AppTheme.textSecondary)
          }
        }
      }
    }
  }

  // MARK: - Health Score

  private var healthSection: some View {
    HStack(spacing: AppTheme.Space.md) {
      HStack(spacing: AppTheme.Space.xxs) {
        ForEach(1...5, id: \.self) { star in
          Image(systemName: star <= scoredRecipe.healthScore.rating ? "star.fill" : "star")
            .font(.system(size: 14))
            .foregroundStyle(
              star <= scoredRecipe.healthScore.rating
                ? AppTheme.accent : AppTheme.oat.opacity(0.4))
        }
      }

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(scoredRecipe.healthScore.label)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textPrimary)
        Text(scoredRecipe.healthScore.reasoning)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Spacer()
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.sage.opacity(0.06),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.sage.opacity(0.15), lineWidth: 1)
    )
  }

  // MARK: - Macros

  private var macroSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("Nutrition", subtitle: "Per serving", icon: "chart.bar")

        HStack(spacing: AppTheme.Space.sm) {
          macroCell(
            "Calories", value: "\(Int(macros.caloriesPerServing))", unit: "kcal",
            color: AppTheme.accent)
          macroCell(
            "Protein", value: "\(Int(macros.proteinPerServing))", unit: "g",
            color: AppTheme.sage)
          macroCell(
            "Carbs", value: "\(Int(macros.carbsPerServing))", unit: "g",
            color: AppTheme.oat)
          macroCell(
            "Fat", value: "\(Int(macros.fatPerServing))", unit: "g",
            color: AppTheme.accentLight)
        }

        macroSplitBar
      }
    }
  }

  private func macroCell(_ label: String, value: String, unit: String, color: Color) -> some View {
    VStack(spacing: AppTheme.Space.xxs) {
      Text(value)
        .font(AppTheme.Typography.dataMedium)
        .foregroundStyle(color)
        .contentTransition(.numericText())
      Text(unit)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
      Text(label)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var macroSplitBar: some View {
    let split = macros.macroSplit
    return GeometryReader { geo in
      HStack(spacing: AppTheme.Space.xxxs) {
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.sage)
          .frame(width: max(2, geo.size.width * split.proteinPct))
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.oat)
          .frame(width: max(2, geo.size.width * split.carbsPct))
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.accentLight)
          .frame(width: max(2, geo.size.width * split.fatPct))
      }
    }
    .frame(height: 8)
    .clipShape(Capsule())
  }

  // MARK: - Ingredients

  private var ingredientSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Ingredients",
          subtitle: "\(ingredients.count) items",
          icon: "carrot.fill"
        )

        let required = ingredients.filter { $0.quantity.isRequired }
        let optional = ingredients.filter { !$0.quantity.isRequired }

        if !required.isEmpty {
          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            ForEach(required, id: \.ingredient.id) { item in
              ingredientRow(item.ingredient, quantity: item.quantity, isRequired: true)
            }
          }
        }

        if !optional.isEmpty {
          Text("Optional")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.top, AppTheme.Space.xs)

          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            ForEach(optional, id: \.ingredient.id) { item in
              ingredientRow(item.ingredient, quantity: item.quantity, isRequired: false)
            }
          }
        }
      }
    }
  }

  private func ingredientRow(
    _ ingredient: Ingredient, quantity: RecipeIngredient, isRequired: Bool
  ) -> some View {
    Button {
      selectedIngredientForDetail = ingredient
    } label: {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: isRequired ? "checkmark.circle.fill" : "circle.dashed")
          .foregroundStyle(isRequired ? AppTheme.positive : AppTheme.textSecondary)
          .font(AppTheme.Typography.label)

        Text(ingredient.displayName)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)

        Spacer()

        Text(quantity.displayQuantity)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .padding(.horizontal, AppTheme.Space.xs)
      .padding(.vertical, AppTheme.Space.xs)
      .background(
        AppTheme.surfaceMuted.opacity(0.4),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Bottom CTA

  private var bottomCTA: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(AppTheme.oat.opacity(0.30))
        .frame(height: 1)

      VStack(spacing: AppTheme.Space.xs) {
        FLPrimaryButton("Start Cooking", systemImage: "flame.fill") {
          onStartCooking()
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.vertical, AppTheme.Space.md)
      .background(AppTheme.bg)
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
    // Check if there's a previous cooking with a photo for this recipe
    if let path = try? deps.userDataRepository.latestPhotoPath(forRecipeId: recipeId) {
      existingPhoto = deps.imageStorageService.load(relativePath: path)
    }
  }
}
