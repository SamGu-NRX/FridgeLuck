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

  // Navigation state for drawer → book flow
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
    // Preview drawer (sheet ~92%)
    .sheet(item: $selectedRecipe) { recipe in
      RecipePreviewDrawer(scoredRecipe: recipe) {
        // "Start Cooking" tapped — dismiss drawer, then open book
        selectedRecipe = nil
        // Small delay to let sheet dismiss before presenting fullScreenCover
        Task {
          try? await Task.sleep(for: .milliseconds(350))
          cookingRecipe = recipe
        }
      }
      .presentationDetents([.fraction(0.92)])
      .presentationDragIndicator(.visible)
      .presentationCornerRadius(AppTheme.Radius.xl)
    }
    // Cooking guide (full screen)
    .fullScreenCover(item: $cookingRecipe) { recipe in
      CookingGuideView(scoredRecipe: recipe) {
        // Cooking complete (celebration "Done" tapped)
        // Dismiss the fullScreenCover first, then return to Home after the animation settles.
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
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("Based on \(ingredientIds.count) ingredient\(ingredientIds.count == 1 ? "" : "s")")
        .font(AppTheme.Typography.displaySmall)
        .foregroundStyle(AppTheme.textPrimary)

      Text(engine.explanationPayload.policySummary)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)

      if !engine.explanationPayload.activeDietaryBadges.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: AppTheme.Space.xs) {
            ForEach(engine.explanationPayload.activeDietaryBadges, id: \.self) { badge in
              statusChip(label: badge, icon: "line.3.horizontal.decrease.circle")
            }
          }
        }
      }

      if !engine.recommendations.isEmpty {
        HStack(spacing: AppTheme.Space.sm) {
          statusChip(label: "\(engine.sections.exact.count) exact", icon: "checkmark.circle")
          if !engine.sections.nearMatch.isEmpty {
            statusChip(
              label: "\(engine.sections.nearMatch.count) near", icon: "exclamationmark.circle")
          }
          if let quick = engine.quickSuggestion {
            statusChip(label: "\(quick.recipe.timeMinutes)m", icon: "bolt.fill")
          }
        }
      }

      if let aiNotice = engine.aiEnhancementNotice {
        Text(aiNotice)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
  }

  private func statusChip(label: String, icon: String) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Image(systemName: icon)
      Text(label)
    }
    .font(AppTheme.Typography.label)
    .foregroundStyle(AppTheme.textSecondary)
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.chipVertical)
    .background(AppTheme.surfaceMuted, in: Capsule())
  }

  // MARK: - Loading

  private var loadingView: some View {
    VStack(spacing: AppTheme.Space.md) {
      FLAnalyzingPulse()
        .frame(width: 48, height: 48)
      Text("Finding recipes...")
        .font(AppTheme.Typography.displayCaption)
        .foregroundStyle(AppTheme.textPrimary)
      Text("Scoring by ingredient match, nutrition profile, and personalization.")
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xxl)
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
    Button {
      selectedRecipe = scored
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.md) {
        // Floating badge overlapping the top
        HStack {
          Text("BEST MATCH")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(.white)
            .kerning(1.2)
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.chipVertical)
            .background(AppTheme.accent, in: Capsule())
          Spacer()
          HealthBadge(score: scored.healthScore)
        }

        Text(scored.recipe.title)
          .font(AppTheme.Typography.displayMedium)
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(3)
          .multilineTextAlignment(.leading)

        HStack(spacing: AppTheme.Space.md) {
          Label("\(scored.recipe.timeMinutes) min", systemImage: "clock")
          Label(
            "\(scored.matchedRequired)/\(scored.totalRequired) required",
            systemImage: "checkmark.circle"
          )
          Spacer()
        }
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)

        // Macro bar — thin, elegant, no card wrapper
        MacroSummaryBar(macros: scored.macros)

        if !scored.rankingReasons.isEmpty {
          Text(scored.rankingReasons.joined(separator: " • "))
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.page)
      .padding(.vertical, AppTheme.Space.sm)
      .background(AppTheme.surface)
      .clipShape(
        RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
      )
      .overlay(alignment: .bottom) {
        FLTornEdge(seed: scored.recipe.title.hashValue)
          .fill(AppTheme.bg)
          .frame(height: 8)
          .offset(y: 4)
      }
      .shadow(color: AppTheme.Shadow.color, radius: 12, x: 0, y: 6)
    }
    .matchedTransitionSource(id: "best-match", in: transitionNamespace)
    .buttonStyle(.plain)
    .padding(.horizontal, AppTheme.Space.page)
  }

  // MARK: - Staggered Two-Column Grid

  private var allResultsGrid: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("EXACT MATCHES")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.2)

      let columns = [
        GridItem(.flexible(), spacing: AppTheme.Space.sm),
        GridItem(.flexible(), spacing: AppTheme.Space.sm),
      ]

      LazyVGrid(columns: columns, spacing: AppTheme.Space.sm) {
        ForEach(Array(engine.sections.exact.enumerated()), id: \.element.recipe.id) {
          index, scored in
          recipeGridItem(scored: scored, index: index)
            .opacity(index <= revealedCount ? 1 : 0)
            .offset(y: index <= revealedCount ? 0 : 12)
            .animation(
              reduceMotion ? nil : AppMotion.gentle.delay(Double(index) * AppMotion.staggerDelay),
              value: revealedCount
            )
        }
      }
    }
  }

  private var nearMatchSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text("ALMOST THERE")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.2)

      ForEach(engine.sections.nearMatch) { scored in
        Button {
          selectedRecipe = scored
        } label: {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text(scored.recipe.title)
              .font(.system(.headline, design: .serif, weight: .semibold))
              .foregroundStyle(AppTheme.textPrimary)
              .multilineTextAlignment(.leading)

            HStack(spacing: AppTheme.Space.md) {
              Label("\(scored.recipe.timeMinutes)m", systemImage: "clock")
              Label("Missing \(scored.missingRequiredCount)", systemImage: "exclamationmark.circle")
            }
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)

            if !scored.missingIngredientIds.isEmpty {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Space.xs) {
                  ForEach(scored.missingIngredientIds, id: \.self) { ingredientID in
                    Text(IngredientLexicon.displayName(for: ingredientID))
                      .font(AppTheme.Typography.labelSmall)
                      .foregroundStyle(AppTheme.textSecondary)
                      .padding(.horizontal, AppTheme.Space.sm)
                      .padding(.vertical, AppTheme.Space.chipVertical)
                      .background(AppTheme.surfaceMuted, in: Capsule())
                  }
                }
              }
            }

            if !scored.rankingReasons.isEmpty {
              Text(scored.rankingReasons.joined(separator: " • "))
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(AppTheme.Space.md)
          .background(
            AppTheme.surface,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
              .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func recipeGridItem(scored: ScoredRecipe, index: Int) -> some View {
    let isOdd = index % 2 == 1

    return Button {
      selectedRecipe = scored
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        // Floating match percentage
        Text("\(scored.matchedRequired)/\(scored.totalRequired)")
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(AppTheme.accent)

        Text(scored.recipe.title)
          .font(.system(.subheadline, design: .serif, weight: .semibold))
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)

        HStack(spacing: AppTheme.Space.xxs) {
          Image(systemName: "clock")
          Text("\(scored.recipe.timeMinutes)m")
        }
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)

        Spacer(minLength: 0)

        // Inline macro summary
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          miniMacro("P", value: Int(scored.macros.proteinPerServing), color: AppTheme.sage)
          miniMacro("C", value: Int(scored.macros.carbsPerServing), color: AppTheme.oat)
          miniMacro("F", value: Int(scored.macros.fatPerServing), color: AppTheme.accentLight)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.md)
      .frame(minHeight: isOdd ? 180 : 160)
      .background(
        AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.color, radius: 6, x: 0, y: 3)
      .offset(y: isOdd ? 16 : 0)
    }
    .matchedTransitionSource(id: transitionID(for: scored), in: transitionNamespace)
    .buttonStyle(.plain)
  }

  private func miniMacro(_ label: String, value: Int, color: Color) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text("\(label) \(value)g")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  private func transitionID(for scored: ScoredRecipe) -> String {
    let id = scored.recipe.id ?? -1
    return "recipe-card-\(id)"
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

// MARK: - Identifiable conformance for ScoredRecipe sheet binding

extension ScoredRecipe: Equatable {
  static func == (lhs: ScoredRecipe, rhs: ScoredRecipe) -> Bool {
    lhs.recipe.id == rhs.recipe.id
  }
}

extension ScoredRecipe: Hashable {
  func hash(into hasher: inout Hasher) {
    hasher.combine(recipe.id)
  }
}

// MARK: - Health Badge

struct HealthBadge: View {
  let score: HealthScore

  var body: some View {
    HStack(spacing: AppTheme.Space.xxxs) {
      ForEach(1...5, id: \.self) { star in
        Image(systemName: star <= score.rating ? "star.fill" : "star")
          .font(.system(size: 10))
          .foregroundStyle(star <= score.rating ? AppTheme.accent : AppTheme.oat.opacity(0.40))
      }
    }
  }
}

// MARK: - Macro Summary Bar (thin, card-free)

struct MacroSummaryBar: View {
  let macros: RecipeMacros

  var body: some View {
    HStack(spacing: AppTheme.Space.sm) {
      macroItem("Cal", value: "\(Int(macros.caloriesPerServing))", color: AppTheme.accent)
      macroItem("P", value: "\(Int(macros.proteinPerServing))g", color: AppTheme.sage)
      macroItem("C", value: "\(Int(macros.carbsPerServing))g", color: AppTheme.oat)
      macroItem("F", value: "\(Int(macros.fatPerServing))g", color: AppTheme.accentLight)
      Spacer()
    }
  }

  private func macroItem(_ label: String, value: String, color: Color) -> some View {
    HStack(spacing: AppTheme.Space.xxxs) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text("\(label) \(value)")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }
}
