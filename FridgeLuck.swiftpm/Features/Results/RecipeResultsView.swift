import SwiftUI

/// Shows recipe recommendations based on the user's available ingredients.
struct RecipeResultsView: View {
  let ingredientIds: Set<Int64>

  @StateObject private var engine: RecommendationEngine

  init(ingredientIds: Set<Int64>, engine: RecommendationEngine) {
    self.ingredientIds = ingredientIds
    _engine = StateObject(wrappedValue: engine)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if engine.isLoading {
          loadingView
        } else if engine.recommendations.isEmpty {
          emptyView
        } else {
          if let pick = engine.quickSuggestion {
            quickPickSection(pick)
          }
          allResultsSection
        }
      }
      .padding()
    }
    .navigationTitle("Recipes")
    .navigationBarTitleDisplayMode(.large)
    .task {
      await engine.findRecipes(for: ingredientIds)
    }
  }

  // MARK: - Loading

  private var loadingView: some View {
    VStack(spacing: 16) {
      Spacer(minLength: 100)
      ProgressView()
        .controlSize(.large)
      Text("Finding recipes...")
        .font(.headline)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Empty

  private var emptyView: some View {
    VStack(spacing: 16) {
      Spacer(minLength: 80)
      Image(systemName: "tray.fill")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      Text("No recipes found")
        .font(.title3.bold())
      if let error = engine.error {
        Text(error.localizedDescription)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      } else {
        Text("Try adding more ingredients\nor scan another photo.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Quick Pick

  private func quickPickSection(_ recipe: ScoredRecipe) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Quick Pick", systemImage: "bolt.fill")
        .font(.headline)
        .foregroundStyle(.yellow)

      NavigationLink(destination: RecipeDetailView(scoredRecipe: recipe)) {
        RecipeCard(scoredRecipe: recipe, isHighlighted: true)
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - All Results

  private var allResultsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("All Matches (\(engine.recommendations.count))")
        .font(.headline)

      ForEach(engine.recommendations, id: \.recipe.id) { scored in
        NavigationLink(destination: RecipeDetailView(scoredRecipe: scored)) {
          RecipeCard(scoredRecipe: scored, isHighlighted: false)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Recipe Card

struct RecipeCard: View {
  let scoredRecipe: ScoredRecipe
  let isHighlighted: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Title row
      HStack {
        Text(scoredRecipe.recipe.title)
          .font(.headline)
          .lineLimit(2)
        Spacer()
        HealthBadge(score: scoredRecipe.healthScore)
      }

      // Meta row
      HStack(spacing: 16) {
        Label("\(scoredRecipe.recipe.timeMinutes) min", systemImage: "clock")
        Label(
          "\(scoredRecipe.recipe.servings) serving\(scoredRecipe.recipe.servings > 1 ? "s" : "")",
          systemImage: "person")
        Spacer()
        Text(scoredRecipe.recipe.recipeTags.labels.prefix(2).joined(separator: ", "))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      // Macros bar
      MacroSummaryBar(macros: scoredRecipe.macros)
    }
    .padding()
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(isHighlighted ? .yellow.opacity(0.08) : Color(.systemBackground))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(isHighlighted ? .yellow.opacity(0.4) : .gray.opacity(0.2), lineWidth: 1)
    )
  }
}

// MARK: - Health Badge

struct HealthBadge: View {
  let score: HealthScore

  var body: some View {
    HStack(spacing: 2) {
      ForEach(1...5, id: \.self) { star in
        Image(systemName: star <= score.rating ? "star.fill" : "star")
          .font(.system(size: 10))
          .foregroundStyle(star <= score.rating ? .yellow : .gray.opacity(0.3))
      }
    }
  }
}

// MARK: - Macro Summary Bar

struct MacroSummaryBar: View {
  let macros: RecipeMacros

  var body: some View {
    HStack(spacing: 12) {
      macroItem("Cal", value: "\(Int(macros.caloriesPerServing))", color: .orange)
      macroItem("P", value: "\(Int(macros.proteinPerServing))g", color: .blue)
      macroItem("C", value: "\(Int(macros.carbsPerServing))g", color: .green)
      macroItem("F", value: "\(Int(macros.fatPerServing))g", color: .red)
      Spacer()
    }
  }

  private func macroItem(_ label: String, value: String, color: Color) -> some View {
    HStack(spacing: 3) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text("\(label) \(value)")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}
