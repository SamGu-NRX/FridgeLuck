import FLFeatureLogic
import SwiftUI

/// MyFitnessPal-inspired recipe picker with two sections:
///
/// 1. **Suggested** — candidate recipes ranked by detection confidence
///    (from ReverseScanAnalysis, when available)
/// 2. **All Recipes** — catalog originals and the legacy recipes the audit keeps, searchable
///    by title
///
/// Presented as a sheet from ReverseScanMealView.
struct RecipePickerView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let analysis: ReverseScanAnalysis?
  let onSelect: (MealLogPick) -> Void

  @State private var searchText = ""
  @State private var allRecipes: [HouseholdScreenedRecipe] = []
  /// How many recipes an empty search lists, so a search with no match can say what it searched.
  @State private var totalRecipeCount: Int?
  @State private var loadFailed = false
  @State private var selectionError: String?
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
        ToolbarItem(placement: .primaryAction) {
          NavigationLink("Plan for guests") {
            GuestMealPlanView()
          }
          .frame(minHeight: 44)
          .accessibilityLabel("Plan for guests")
          .accessibilityValue("Choose a menu and review groceries")
        }
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
      .alert(
        "Couldn't select this recipe",
        isPresented: Binding(
          get: { selectionError != nil }, set: { if !$0 { selectionError = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(selectionError ?? "")
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
            ? "No results" : "\(allRecipes.count) recipe\(allRecipes.count == 1 ? "" : "s")"
        )

        if loadFailed {
          loadFailedView
        } else if allRecipes.isEmpty {
          noResultsView
        } else {
          ForEach(
            Array(allRecipes.enumerated()),
            id: \.element.listID
          ) { index, entry in
            recipeRow(entry, index: index)

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

  /// A recipe the household screen refuses stays in the list, because this picker logs a
  /// meal already eaten; it is never shown plain. The reason sits under the title behind the
  /// warning icon the reverse-scan results use. The text stays in primary color: the warning
  /// color measures 3.65:1 on the light page background, under the 4.5:1 small text needs.
  private func recipeRow(_ entry: HouseholdScreenedRecipe, index: Int) -> some View {
    let recipe = entry.recipe
    return Button {
      selectRecipe(entry)
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

            Text("\(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")")
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

          if let warning = entry.warning {
            HStack(spacing: AppTheme.Space.xxs) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.warning)
                .accessibilityHidden(true)
              Text(warning)
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(2)
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
    .accessibilityHint(entry.warning == nil ? "" : "Flagged for your household. You can still log it.")
    .animation(
      reduceMotion
        ? nil
        : AppMotion.cardSpring.delay(Double(min(index, 12)) * 0.025),
      value: resultsToken
    )
  }

  // MARK: - No Results

  /// A search that matched nothing says what it searched. "Check spelling" used to show here
  /// while the picker could see only 38 of the app's recipes, blaming a correctly typed query.
  private var noResultsView: some View {
    emptyState(
      symbol: "magnifyingglass",
      title: "No recipes match \u{201C}\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}",
      detail: totalRecipeCount.map {
        "Search looks at the names of all \($0) recipe\($0 == 1 ? "" : "s")."
      } ?? "Search looks at recipe names.")
  }

  private var loadFailedView: some View {
    emptyState(
      symbol: "exclamationmark.triangle",
      title: "Recipes didn't load",
      detail: "Close this sheet and open it again to retry.")
  }

  private func emptyState(symbol: String, title: String, detail: String) -> some View {
    VStack(spacing: AppTheme.Space.md) {
      ZStack {
        Circle()
          .fill(AppTheme.dustyRose.opacity(0.08))
          .frame(width: 72, height: 72)
        Image(systemName: symbol)
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(AppTheme.dustyRose.opacity(0.55))
      }
      .accessibilityHidden(true)

      VStack(spacing: AppTheme.Space.xxs) {
        Text(title)
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)

        Text(detail)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.xl)
    .accessibilityElement(children: .combine)
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
    onSelect(
      MealLogPick(
        recipe: candidate.recipe.recipe,
        macros: candidate.recipe.macros,
        catalogRef: candidate.recipe.catalog?.ref))
    dismiss()
  }

  private func selectRecipe(_ entry: HouseholdScreenedRecipe) {
    if let catalogRef = entry.catalogRef {
      do {
        onSelect(try deps.recipeRepository.catalogMealLogPick(catalogRef))
        dismiss()
      } catch {
        selectionError = error.localizedDescription
      }
      return
    }

    let recipe = entry.recipe
    guard let recipeId = recipe.id else { return }
    do {
      let macros = try deps.nutritionService.macros(for: recipeId)
      onSelect(MealLogPick(recipe: recipe, macros: macros, catalogRef: nil))
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
      onSelect(MealLogPick(recipe: recipe, macros: fallback, catalogRef: nil))
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

    do {
      allRecipes = try deps.recipeRepository.mealLogRecipes(
        matching: trimmed, limit: trimmed.isEmpty ? Self.fullListLimit : Self.searchLimit)
      if trimmed.isEmpty { totalRecipeCount = allRecipes.count }
      loadFailed = false
    } catch {
      allRecipes = []
      loadFailed = true
    }

    resultsToken = UUID()
  }

  /// Above the shipped total (762 catalog originals and 38 legacy recipes), so an empty search
  /// lists every recipe.
  private static let fullListLimit = 2_000
  private static let searchLimit = 200
}

extension HouseholdScreenedRecipe {
  /// Stable list identity: catalog entries carry no `recipe.id`.
  fileprivate var listID: String {
    if let catalogRef { return "catalog-\(catalogRef.id)" }
    return "legacy-\(recipe.id ?? -1)-\(recipe.title)"
  }
}

// MARK: - Row Button Style

private struct RecipeRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        configuration.isPressed
          ? AppTheme.oat.opacity(0.10)
          : Color.clear,
        in: RoundedRectangle(
          cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .pressFeedback(isPressed: configuration.isPressed, scale: 0.985, animation: AppMotion.press)
  }
}
