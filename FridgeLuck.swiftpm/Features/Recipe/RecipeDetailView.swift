import SwiftUI

/// Full recipe detail: instructions, ingredients with quantities, macro breakdown, health score.
struct RecipeDetailView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let scoredRecipe: ScoredRecipe

  @State private var ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)] = []
  @State private var showCookedConfirmation = false
  @State private var selectedIngredientForDetail: Ingredient?
  @State private var completedSteps: Set<Int> = []

  private var recipe: Recipe { scoredRecipe.recipe }
  private var macros: RecipeMacros { scoredRecipe.macros }
  private var instructionSteps: [String] {
    recipe.instructions
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        heroSection
        healthSection
        macroSection
        ingredientSection
        instructionSection
      }
      .padding(.horizontal, AppTheme.Space.md)
      .padding(.top, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.xl)
    }
    .navigationTitle(recipe.title)
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .safeAreaInset(edge: .bottom) {
      cookActionBar
    }
    .alert("Mark as Cooked?", isPresented: $showCookedConfirmation) {
      Button("Yes") { markAsCooked() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will add to your cooking history and streak.")
    }
    .task {
      await loadIngredients()
    }
    .sheet(item: $selectedIngredientForDetail) { ingredient in
      IngredientDetailSheet(ingredient: ingredient)
    }
  }

  // MARK: - Hero

  private var heroSection: some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            Text(recipe.title)
              .font(.title2.bold())
              .foregroundStyle(AppTheme.textPrimary)
            Text(
              "\(recipe.timeMinutes) min · \(recipe.servings) serving\(recipe.servings > 1 ? "s" : "")"
            )
            .font(.subheadline)
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
                .font(.caption2)
                .padding(.horizontal, AppTheme.Space.sm)
                .padding(.vertical, AppTheme.Space.xs)
                .background(AppTheme.surface, in: Capsule())
            }
          }
        }
      }
    }
  }

  // MARK: - Health Score

  private var healthSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Health Signal", subtitle: scoredRecipe.healthScore.reasoning, icon: "heart.text.square")

        HStack(spacing: AppTheme.Space.xs) {
          ForEach(1...5, id: \.self) { star in
            Image(systemName: star <= scoredRecipe.healthScore.rating ? "star.fill" : "star")
              .foregroundStyle(
                star <= scoredRecipe.healthScore.rating
                  ? AppTheme.accent : AppTheme.neutral.opacity(0.4))
          }
          Text(scoredRecipe.healthScore.label)
            .font(.subheadline.bold())
            .foregroundStyle(AppTheme.textPrimary)
        }
      }
    }
  }

  // MARK: - Macros

  private var macroSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("Nutrition", subtitle: "Per serving", icon: "chart.bar")

        HStack(spacing: AppTheme.Space.sm) {
          macroCell(
            "Calories", value: "\(Int(macros.caloriesPerServing))", unit: "kcal", color: .orange)
          macroCell("Protein", value: "\(Int(macros.proteinPerServing))", unit: "g", color: .blue)
          macroCell("Carbs", value: "\(Int(macros.carbsPerServing))", unit: "g", color: .green)
          macroCell("Fat", value: "\(Int(macros.fatPerServing))", unit: "g", color: .red)
        }

        HStack(spacing: AppTheme.Space.md) {
          miniNutrient("Fiber", value: String(format: "%.1fg", macros.fiberPerServing))
          miniNutrient("Sugar", value: String(format: "%.1fg", macros.sugarPerServing))
          miniNutrient("Sodium", value: "\(Int(macros.sodiumPerServing))mg")
          Spacer()
        }

        macroSplitBar
      }
    }
  }

  private func macroCell(_ label: String, value: String, unit: String, color: Color) -> some View {
    VStack(spacing: AppTheme.Space.xxs) {
      Text(value)
        .font(.title3.bold())
        .foregroundStyle(color)
      Text(unit)
        .font(.caption2)
        .foregroundStyle(AppTheme.textSecondary)
      Text(label)
        .font(.caption)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
  }

  private func miniNutrient(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text(value)
        .font(.caption.bold())
        .foregroundStyle(AppTheme.textPrimary)
      Text(label)
        .font(.caption2)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  private var macroSplitBar: some View {
    let split = macros.macroSplit
    return GeometryReader { geo in
      HStack(spacing: 2) {
        RoundedRectangle(cornerRadius: 4)
          .fill(.blue)
          .frame(width: max(2, geo.size.width * split.proteinPct))
        RoundedRectangle(cornerRadius: 4)
          .fill(.green)
          .frame(width: max(2, geo.size.width * split.carbsPct))
        RoundedRectangle(cornerRadius: 4)
          .fill(.red)
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
          "Ingredients", subtitle: "Tap any ingredient for details", icon: "carrot.fill")

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
            .font(.caption.weight(.semibold))
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

  private func ingredientRow(_ ingredient: Ingredient, quantity: RecipeIngredient, isRequired: Bool)
    -> some View
  {
    Button {
      selectedIngredientForDetail = ingredient
    } label: {
      HStack(spacing: AppTheme.Space.sm) {
        Image(systemName: isRequired ? "checkmark.circle.fill" : "circle.dashed")
          .foregroundStyle(isRequired ? AppTheme.positive : AppTheme.textSecondary)
          .font(.caption)

        Text(ingredient.displayName)
          .font(.subheadline)
          .foregroundStyle(AppTheme.textPrimary)

        Spacer()

        Text(quantity.displayQuantity)
          .font(.subheadline)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .padding(.horizontal, AppTheme.Space.xs)
      .padding(.vertical, AppTheme.Space.xs)
      .background(
        AppTheme.surfaceMuted.opacity(0.4), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }
    .buttonStyle(.plain)
  }

  // MARK: - Instructions

  private var instructionSection: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Instructions",
          subtitle: "\(completedSteps.count)/\(max(1, instructionSteps.count)) completed",
          icon: "list.number"
        )

        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(AppTheme.textSecondary.opacity(0.16))
            Capsule()
              .fill(AppTheme.accent)
              .frame(width: geo.size.width * instructionProgress)
          }
        }
        .frame(height: 7)

        ForEach(Array(instructionSteps.enumerated()), id: \.offset) { index, step in
          Button {
            toggleStep(index)
          } label: {
            HStack(alignment: .top, spacing: AppTheme.Space.sm) {
              Image(systemName: completedSteps.contains(index) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                  completedSteps.contains(index) ? AppTheme.positive : AppTheme.textSecondary
                )
                .font(.subheadline)

              VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
                Text("Step \(index + 1)")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(AppTheme.textSecondary)
                Text(step)
                  .font(.body)
                  .foregroundStyle(AppTheme.textPrimary)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }

              if completedSteps.contains(index) {
                Image(systemName: "checkmark")
                  .font(.caption.bold())
                  .foregroundStyle(AppTheme.positive)
              }
            }
            .padding(AppTheme.Space.sm)
            .background(
              completedSteps.contains(index)
                ? AppTheme.positive.opacity(0.1) : AppTheme.surfaceMuted.opacity(0.4),
              in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  // MARK: - Cook CTA

  private var cookActionBar: some View {
    FLActionBar {
      FLPrimaryButton("I Made This", systemImage: "frying.pan.fill") {
        showCookedConfirmation = true
      }
      .padding(.horizontal, AppTheme.Space.md)
      .padding(.bottom, AppTheme.Space.md)
    }
  }

  // MARK: - Actions

  private func loadIngredients() async {
    guard let recipeId = recipe.id else { return }
    ingredients = (try? deps.recipeRepository.ingredientsForRecipe(id: recipeId)) ?? []
  }

  private func markAsCooked() {
    guard let recipeId = recipe.id else { return }
    try? deps.personalizationService.recordCooking(recipeId: recipeId)
  }

  private var instructionProgress: Double {
    guard !instructionSteps.isEmpty else { return 0 }
    return Double(completedSteps.count) / Double(instructionSteps.count)
  }

  private func toggleStep(_ index: Int) {
    withAnimation(reduceMotion ? nil : AppMotion.quick) {
      if completedSteps.contains(index) {
        completedSteps.remove(index)
      } else {
        completedSteps.insert(index)
      }
    }
  }
}
