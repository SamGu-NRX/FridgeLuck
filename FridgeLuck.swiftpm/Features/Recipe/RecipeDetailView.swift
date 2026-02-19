import SwiftUI

/// Full recipe detail: instructions, ingredients with quantities, macro breakdown, health score.
struct RecipeDetailView: View {
  @EnvironmentObject var deps: AppDependencies
  let scoredRecipe: ScoredRecipe

  @State private var ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)] = []
  @State private var showCookedConfirmation = false
  @State private var selectedIngredientForDetail: Ingredient?

  private var recipe: Recipe { scoredRecipe.recipe }
  private var macros: RecipeMacros { scoredRecipe.macros }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        headerSection
        healthSection
        macroSection
        ingredientSection
        instructionSection
        cookButton
      }
      .padding()
    }
    .navigationTitle(recipe.title)
    .navigationBarTitleDisplayMode(.inline)
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

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("\(recipe.timeMinutes) min", systemImage: "clock")
        Label("\(recipe.servings) serving\(recipe.servings > 1 ? "s" : "")", systemImage: "person")
        Spacer()
        if recipe.source == .aiGenerated {
          Label("AI", systemImage: "sparkles")
            .font(.caption.bold())
            .foregroundStyle(.purple)
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)

      // Tags
      if !recipe.recipeTags.labels.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(recipe.recipeTags.labels, id: \.self) { tag in
            Text(tag.replacingOccurrences(of: "_", with: " "))
              .font(.caption2)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(.yellow.opacity(0.15))
              .clipShape(Capsule())
          }
        }
      }
    }
  }

  // MARK: - Health Score

  private var healthSection: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          ForEach(1...5, id: \.self) { star in
            Image(systemName: star <= scoredRecipe.healthScore.rating ? "star.fill" : "star")
              .foregroundStyle(
                star <= scoredRecipe.healthScore.rating ? .yellow : .gray.opacity(0.3))
          }
          Text(scoredRecipe.healthScore.label)
            .font(.subheadline.bold())
        }
        Text(scoredRecipe.healthScore.reasoning)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(.yellow.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(.yellow.opacity(0.2), lineWidth: 1)
    )
  }

  // MARK: - Macros

  private var macroSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Nutrition (per serving)")
        .font(.headline)

      HStack(spacing: 0) {
        macroCard(
          "Calories", value: "\(Int(macros.caloriesPerServing))", unit: "kcal", color: .orange)
        macroCard("Protein", value: "\(Int(macros.proteinPerServing))", unit: "g", color: .blue)
        macroCard("Carbs", value: "\(Int(macros.carbsPerServing))", unit: "g", color: .green)
        macroCard("Fat", value: "\(Int(macros.fatPerServing))", unit: "g", color: .red)
      }

      // Additional nutrients
      HStack(spacing: 16) {
        miniNutrient("Fiber", value: String(format: "%.1fg", macros.fiberPerServing))
        miniNutrient("Sugar", value: String(format: "%.1fg", macros.sugarPerServing))
        miniNutrient("Sodium", value: "\(Int(macros.sodiumPerServing))mg")
        Spacer()
      }
      .padding(.top, 4)

      // Macro split bar
      macroSplitBar
    }
  }

  private func macroCard(_ label: String, value: String, unit: String, color: Color) -> some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.title2.bold())
        .foregroundStyle(color)
      Text(unit)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private func miniNutrient(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.caption.bold())
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
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
    VStack(alignment: .leading, spacing: 12) {
      Text("Ingredients")
        .font(.headline)

      let required = ingredients.filter { $0.quantity.isRequired }
      let optional = ingredients.filter { !$0.quantity.isRequired }

      if !required.isEmpty {
        ForEach(required, id: \.ingredient.id) { item in
          ingredientRow(item.ingredient, quantity: item.quantity, isRequired: true)
        }
      }

      if !optional.isEmpty {
        Text("Optional")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.top, 4)

        ForEach(optional, id: \.ingredient.id) { item in
          ingredientRow(item.ingredient, quantity: item.quantity, isRequired: false)
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
      HStack {
        Image(systemName: isRequired ? "checkmark.circle.fill" : "circle.dashed")
          .foregroundStyle(isRequired ? .green : .secondary)
          .font(.caption)
        Text(ingredient.displayName)
        Spacer()
        Text(quantity.displayQuantity)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 2)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Instructions

  private var instructionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Instructions")
        .font(.headline)

      let steps = recipe.instructions.components(separatedBy: "\n")
      ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
        let trimmed = step.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          Text(trimmed)
            .font(.body)
            .padding(.vertical, 2)
        }
      }
    }
  }

  // MARK: - Cook Button

  private var cookButton: some View {
    Button {
      showCookedConfirmation = true
    } label: {
      Label("I Made This!", systemImage: "frying.pan.fill")
        .frame(maxWidth: .infinity)
        .padding()
        .background(.yellow)
        .foregroundStyle(.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .font(.headline)
    }
    .padding(.top, 8)
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
}
