import SwiftUI

/// MyFitnessPal-inspired recipe picker with two sections:
///
/// 1. **Suggested** — candidate recipes ranked by detection confidence
///    (from ReverseScanAnalysis, when available)
/// 2. **All Recipes** — full catalog, searchable by title
///
/// Presented as a sheet from ReverseScanMealView.
struct RecipePickerView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let analysis: ReverseScanAnalysis?
  let onSelect: (Recipe, RecipeMacros) -> Void

  @State private var searchText = ""
  @State private var allRecipes: [Recipe] = []
  @State private var isLoading = false
  @State private var resultsToken = UUID()

  private var hasSuggestions: Bool {
    guard let analysis else { return false }
    return !analysis.candidateRecipes.isEmpty
  }

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          loadingView
        } else {
          recipeList
        }
      }
      .navigationTitle("Select Recipe")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search recipes")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .task {
        await runSearch(query: "", bypassDebounce: true)
      }
      .task(id: searchText) {
        await runSearch(query: searchText, bypassDebounce: false)
      }
    }
    .flPageBackground()
  }

  // MARK: - Loading

  private var loadingView: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Spacer()
      FLAnalyzingPulse()
        .frame(width: 36, height: 36)
      Text("Loading recipes...")
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Recipe List

  private var recipeList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        // Suggested section
        if hasSuggestions, searchText.isEmpty, let analysis {
          sectionHeader(
            "Suggested for your meal",
            icon: "sparkles",
            subtitle:
              "\(analysis.candidateRecipes.count) match\(analysis.candidateRecipes.count == 1 ? "" : "es") based on detected ingredients"
          )

          ForEach(
            Array(analysis.candidateRecipes.prefix(6).enumerated()),
            id: \.element.id
          ) { index, candidate in
            suggestedRow(candidate, index: index)

            if index < min(analysis.candidateRecipes.count, 6) - 1 {
              rowDivider
            }
          }

          sectionSpacer
        }

        // All recipes section
        sectionHeader(
          "All Recipes",
          icon: "book.closed.fill",
          subtitle: allRecipes.isEmpty
            ? "No results" : "\(allRecipes.count) recipes"
        )

        if allRecipes.isEmpty {
          noResultsView
        } else {
          ForEach(
            Array(allRecipes.enumerated()),
            id: \.element.id
          ) { index, recipe in
            recipeRow(recipe, index: index)

            if index < allRecipes.count - 1 {
              rowDivider
            }
          }
        }

        Spacer(minLength: AppTheme.Space.xxl)
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xs)
      .id(resultsToken)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  // MARK: - Section Header

  private func sectionHeader(
    _ title: String, icon: String, subtitle: String
  ) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: icon)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
        Text(title.uppercased())
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .kerning(1.2)
      }

      Text(subtitle)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
    }
    .padding(.top, AppTheme.Space.md)
    .padding(.bottom, AppTheme.Space.sm)
  }

  private var sectionSpacer: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.14))
      .frame(height: 1)
      .padding(.vertical, AppTheme.Space.sm)
  }

  // MARK: - Suggested Row

  private func suggestedRow(
    _ candidate: ReverseScanRecipeCandidate, index: Int
  ) -> some View {
    Button {
      selectCandidate(candidate)
    } label: {
      HStack(spacing: AppTheme.Space.sm) {
        recipeIcon(for: candidate.recipe.recipe)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(candidate.recipe.recipe.title)
            .font(.system(.subheadline, design: .serif, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(2)

          HStack(spacing: AppTheme.Space.xs) {
            Text(
              "\(Int((candidate.confidenceScore * 100).rounded()))% match"
            )
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(
              candidate.confidenceScore >= 0.7
                ? AppTheme.sage : AppTheme.textSecondary
            )

            Text("·")
              .foregroundStyle(AppTheme.textSecondary)

            Text(candidate.recipe.macros.summaryText)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 4)

        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(AppTheme.oat.opacity(0.5))
      }
      .padding(.vertical, AppTheme.Space.sm)
      .contentShape(Rectangle())
    }
    .buttonStyle(RecipeRowButtonStyle())
    .animation(
      reduceMotion
        ? nil
        : AppMotion.cardSpring.delay(Double(min(index, 8)) * 0.025),
      value: resultsToken
    )
  }

  // MARK: - Recipe Row

  private func recipeRow(_ recipe: Recipe, index: Int) -> some View {
    Button {
      selectRecipe(recipe)
    } label: {
      HStack(spacing: AppTheme.Space.sm) {
        recipeIcon(for: recipe)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(recipe.title)
            .font(.system(.subheadline, design: .serif, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(2)

          HStack(spacing: AppTheme.Space.xs) {
            HStack(spacing: AppTheme.Space.xxs) {
              Image(systemName: "clock")
                .font(.system(size: 10))
              Text("\(recipe.timeMinutes) min")
                .font(AppTheme.Typography.labelSmall)
            }
            .foregroundStyle(AppTheme.textSecondary)

            Text("·")
              .foregroundStyle(AppTheme.textSecondary)

            Text("\(recipe.servings) servings")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)

            if !recipe.recipeTags.labels.isEmpty {
              Text("·")
                .foregroundStyle(AppTheme.textSecondary)
              Text(recipe.recipeTags.labels.prefix(2).joined(separator: ", "))
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.sage)
                .lineLimit(1)
            }
          }
        }

        Spacer(minLength: 4)

        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(AppTheme.oat.opacity(0.5))
      }
      .padding(.vertical, AppTheme.Space.sm)
      .contentShape(Rectangle())
    }
    .buttonStyle(RecipeRowButtonStyle())
    .animation(
      reduceMotion
        ? nil
        : AppMotion.cardSpring.delay(Double(min(index, 12)) * 0.025),
      value: resultsToken
    )
  }

  // MARK: - No Results

  private var noResultsView: some View {
    VStack(spacing: AppTheme.Space.md) {
      ZStack {
        Circle()
          .fill(AppTheme.dustyRose.opacity(0.08))
          .frame(width: 72, height: 72)
        Image(systemName: "magnifyingglass")
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(AppTheme.dustyRose.opacity(0.55))
      }

      VStack(spacing: AppTheme.Space.xxs) {
        Text("Nothing for \u{201C}\(searchText)\u{201D}")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)

        Text("Try a shorter name or check spelling.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xl)
  }

  // MARK: - Recipe Icon

  private func recipeIcon(for recipe: Recipe) -> some View {
    let tags = recipe.recipeTags
    let (symbol, tint): (String, Color) = {
      if tags.contains(.breakfast) { return ("sunrise.fill", AppTheme.accent) }
      if tags.contains(.asian) { return ("takeoutbag.and.cup.and.straw.fill", AppTheme.sage) }
      if tags.contains(.vegetarian) || tags.contains(.vegan) {
        return ("leaf.fill", AppTheme.sage)
      }
      if tags.contains(.highProtein) {
        return ("fork.knife", Color(red: 0.68, green: 0.56, blue: 0.42))
      }
      if tags.contains(.comfort) { return ("flame.fill", AppTheme.accent) }
      return ("fork.knife.circle", AppTheme.textSecondary)
    }()

    return Image(systemName: symbol)
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: 36, height: 36)
      .background(
        FLOrganicBlob(seed: recipe.title.hashValue)
          .fill(tint.opacity(0.12))
      )
      .overlay(
        FLOrganicBlob(seed: recipe.title.hashValue)
          .stroke(tint.opacity(0.20), lineWidth: 0.8)
      )
  }

  // MARK: - Divider

  private var rowDivider: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.18))
      .frame(height: 1)
      .padding(.leading, 52)
  }

  // MARK: - Actions

  private func selectCandidate(_ candidate: ReverseScanRecipeCandidate) {
    onSelect(candidate.recipe.recipe, candidate.recipe.macros)
    dismiss()
  }

  private func selectRecipe(_ recipe: Recipe) {
    guard let recipeId = recipe.id else { return }
    do {
      let macros = try deps.nutritionService.macros(for: recipeId)
      onSelect(recipe, macros)
      dismiss()
    } catch {
      // If macros fail, still select with zero-macros fallback
      let fallback = RecipeMacros(
        caloriesPerServing: 0,
        proteinPerServing: 0,
        carbsPerServing: 0,
        fatPerServing: 0,
        fiberPerServing: 0,
        sugarPerServing: 0,
        sodiumPerServing: 0
      )
      onSelect(recipe, fallback)
      dismiss()
    }
  }

  // MARK: - Data Loading

  private func runSearch(query: String, bypassDebounce: Bool) async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    if !bypassDebounce {
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      guard trimmed == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return
      }
    }

    isLoading = true
    defer { isLoading = false }

    if trimmed.isEmpty {
      allRecipes = (try? deps.recipeRepository.fetchAllRecipes(limit: 300)) ?? []
    } else {
      allRecipes = (try? deps.recipeRepository.searchRecipes(query: trimmed, limit: 100)) ?? []
    }

    resultsToken = UUID()
  }
}

// MARK: - Row Button Style

private struct RecipeRowButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        configuration.isPressed
          ? AppTheme.oat.opacity(0.10)
          : Color.clear,
        in: RoundedRectangle(
          cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(
        reduceMotion ? nil : AppMotion.press, value: configuration.isPressed)
  }
}
