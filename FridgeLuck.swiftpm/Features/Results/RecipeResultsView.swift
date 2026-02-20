import SwiftUI

/// Shows recipe recommendations based on the user's available ingredients.
struct RecipeResultsView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let ingredientIds: Set<Int64>

  @StateObject private var engine: RecommendationEngine
  @Namespace private var transitionNamespace
  @State private var revealedCount: Int = 0

  init(ingredientIds: Set<Int64>, engine: RecommendationEngine) {
    self.ingredientIds = ingredientIds
    _engine = StateObject(wrappedValue: engine)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        contextSection

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
      .padding(.horizontal, AppTheme.Space.md)
      .padding(.vertical, AppTheme.Space.md)
    }
    .navigationTitle("Recipes")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .task {
      await engine.findRecipes(for: ingredientIds)
      await revealRecommendationsIfNeeded()
    }
    .onChange(of: engine.recommendations.count) { _, _ in
      Task { await revealRecommendationsIfNeeded() }
    }
  }

  // MARK: - Header Context

  private var contextSection: some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader(
          "Based on \(ingredientIds.count) ingredient\(ingredientIds.count == 1 ? "" : "s")",
          subtitle: "Matches prioritize complete required ingredients first.",
          icon: "fork.knife.circle.fill"
        )

        if !engine.recommendations.isEmpty {
          HStack(spacing: AppTheme.Space.sm) {
            statusChip(label: "\(engine.recommendations.count) matches", icon: "list.bullet")
            if let quick = engine.quickSuggestion {
              statusChip(label: "Quick pick: \(quick.recipe.timeMinutes)m", icon: "bolt.fill")
            }
            statusChip(label: "Tap any card for full steps", icon: "hand.tap")
          }
        }
      }
    }
  }

  private func statusChip(label: String, icon: String) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Image(systemName: icon)
      Text(label)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(AppTheme.textSecondary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.xs)
    .background(AppTheme.surface, in: Capsule())
  }

  // MARK: - Loading

  private var loadingView: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        ProgressView()
          .controlSize(.large)
        Text("Finding recipes...")
          .font(.headline)
          .foregroundStyle(AppTheme.textPrimary)
        Text("Scoring by ingredient match, nutrition profile, and personalization.")
          .font(.subheadline)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.xl)
    }
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

  // MARK: - Quick Pick

  private func quickPickSection(_ recipe: ScoredRecipe) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      FLSectionHeader(
        "Quick Pick",
        subtitle: "Fastest high-quality match right now",
        icon: "bolt.fill"
      )

      recipeLink(for: recipe, highlighted: true)
    }
  }

  // MARK: - All Results

  private var allResultsSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      FLSectionHeader(
        "All Matches (\(engine.recommendations.count))",
        subtitle: "Sorted by combined quality and fit",
        icon: "list.bullet.rectangle"
      )

      ForEach(Array(engine.recommendations.enumerated()), id: \.element.recipe.id) {
        index, scored in
        recipeLink(for: scored, highlighted: false)
          .opacity(index <= revealedCount ? 1 : 0)
          .offset(y: index <= revealedCount ? 0 : 12)
          .animation(
            reduceMotion ? nil : AppMotion.gentle.delay(Double(index) * AppMotion.staggerDelay),
            value: revealedCount
          )
      }
    }
  }

  private func recipeLink(for scored: ScoredRecipe, highlighted: Bool) -> some View {
    NavigationLink {
      RecipeDetailView(scoredRecipe: scored)
        .navigationTransition(.zoom(sourceID: transitionID(for: scored), in: transitionNamespace))
    } label: {
      RecipeCard(scoredRecipe: scored, isHighlighted: highlighted)
        .matchedTransitionSource(id: transitionID(for: scored), in: transitionNamespace)
    }
    .buttonStyle(.plain)
  }

  private func transitionID(for scored: ScoredRecipe) -> String {
    let id = scored.recipe.id ?? -1
    return "recipe-card-\(id)"
  }

  private func revealRecommendationsIfNeeded() async {
    let total = engine.recommendations.count
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

// MARK: - Recipe Card

struct RecipeCard: View {
  let scoredRecipe: ScoredRecipe
  let isHighlighted: Bool

  var body: some View {
    FLCard(tone: isHighlighted ? .warm : .normal) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(alignment: .top, spacing: AppTheme.Space.sm) {
          VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
            Text(scoredRecipe.recipe.title)
              .font(.headline)
              .foregroundStyle(AppTheme.textPrimary)
              .lineLimit(2)

            Text(
              "\(scoredRecipe.matchedRequired)/\(scoredRecipe.totalRequired) required · \(scoredRecipe.matchedOptional) optional"
            )
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
          }

          Spacer()

          HealthBadge(score: scoredRecipe.healthScore)
        }

        HStack(spacing: AppTheme.Space.md) {
          Label("\(scoredRecipe.recipe.timeMinutes) min", systemImage: "clock")
          Label(
            "\(scoredRecipe.recipe.servings) serving\(scoredRecipe.recipe.servings > 1 ? "s" : "")",
            systemImage: "person"
          )
          Spacer()
        }
        .font(.caption)
        .foregroundStyle(AppTheme.textSecondary)

        if !scoredRecipe.recipe.recipeTags.labels.isEmpty {
          FlowLayout(spacing: AppTheme.Space.xs) {
            ForEach(Array(scoredRecipe.recipe.recipeTags.labels.prefix(3)), id: \.self) { tag in
              Text(tag.replacingOccurrences(of: "_", with: " "))
                .font(.caption2)
                .padding(.horizontal, AppTheme.Space.sm)
                .padding(.vertical, AppTheme.Space.xs)
                .background(AppTheme.accent.opacity(0.14), in: Capsule())
            }
          }
        }

        MacroSummaryBar(macros: scoredRecipe.macros)
      }
    }
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
          .foregroundStyle(star <= score.rating ? AppTheme.accent : AppTheme.neutral.opacity(0.4))
      }
    }
  }
}

// MARK: - Macro Summary Bar

struct MacroSummaryBar: View {
  let macros: RecipeMacros

  var body: some View {
    HStack(spacing: AppTheme.Space.sm) {
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
        .foregroundStyle(AppTheme.textSecondary)
    }
  }
}
