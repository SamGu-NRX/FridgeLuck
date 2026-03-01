import SwiftUI

struct IngredientPickerView: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let title: String
  let seedIngredients: [Ingredient]

  @State private var searchText = ""
  @State private var results: [Ingredient] = []
  @State private var isLoading = false
  @State private var resultsRevealToken = UUID()

  private let onPickSingle: ((Ingredient) -> Void)?
  private let selectedIDs: Binding<Set<Int64>>?

  init(
    title: String,
    seedIngredients: [Ingredient] = [],
    onPickSingle: @escaping (Ingredient) -> Void
  ) {
    self.title = title
    self.seedIngredients = seedIngredients
    self.onPickSingle = onPickSingle
    self.selectedIDs = nil
  }

  init(
    title: String,
    seedIngredients: [Ingredient] = [],
    selectedIDs: Binding<Set<Int64>>
  ) {
    self.title = title
    self.seedIngredients = seedIngredients
    self.onPickSingle = nil
    self.selectedIDs = selectedIDs
  }

  private var isMultiSelect: Bool { selectedIDs != nil }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if isMultiSelect {
          multiSelectSummary
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.top, AppTheme.Space.sm)
            .padding(.bottom, AppTheme.Space.xs)
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        Group {
          if results.isEmpty, !isLoading {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              emptyBrowseState
            } else {
              noResultsState
            }
          } else {
            ingredientList
          }
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search ingredients")
      .task {
        await runSearch(query: "", bypassDebounce: true)
      }
      .task(id: searchText) {
        await runSearch(query: searchText, bypassDebounce: false)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .flPageBackground()
    .animation(reduceMotion ? nil : AppMotion.gentle, value: selectedIDs?.wrappedValue.count ?? 0)
  }

  // MARK: - Multi-Select Summary

  private var multiSelectSummary: some View {
    let count = selectedIDs?.wrappedValue.count ?? 0

    return HStack(spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: "checkmark.seal.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(count > 0 ? AppTheme.sage : AppTheme.textSecondary)

        Text("\(count)")
          .font(AppTheme.Typography.dataSmall)
          .foregroundStyle(AppTheme.textPrimary)
          .contentTransition(.numericText())

        Text("selected")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Spacer()

      if count > 0 {
        Button {
          guard var current = selectedIDs?.wrappedValue else { return }
          current.removeAll()
          selectedIDs?.wrappedValue = current
        } label: {
          Text("Clear")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.dustyRose)
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.xxs)
            .background(
              AppTheme.dustyRose.opacity(0.10),
              in: Capsule()
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surfaceMuted.opacity(0.6),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
    )
  }

  // MARK: - Ingredient List

  private var ingredientList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(results.enumerated()), id: \.element.id) { index, ingredient in
          if let id = ingredient.id {
            ingredientRow(ingredient, id: id, index: index)

            if index < results.count - 1 {
              rowDivider
            }
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.top, AppTheme.Space.xs)
      .padding(.bottom, AppTheme.Space.xxl)
      .id(resultsRevealToken)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  private var rowDivider: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.18))
      .frame(height: 1)
      .padding(.leading, 52)
  }

  // MARK: - Ingredient Row

  private func ingredientRow(_ ingredient: Ingredient, id: Int64, index: Int) -> some View {
    let isChosen = isMultiSelect ? isSelected(id) : false

    return Button {
      if isMultiSelect {
        toggleSelection(id)
      } else {
        onPickSingle?(ingredient)
        dismiss()
      }
    } label: {
      HStack(spacing: AppTheme.Space.sm) {
        ingredientIcon(ingredient)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(ingredient.displayName)
            .font(.system(.subheadline, design: .serif, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(1)

          if let desc = ingredient.description, !desc.isEmpty {
            Text(desc)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
              .lineLimit(1)
          } else if let category = ingredient.categoryLabel, !category.isEmpty {
            Text(category.replacingOccurrences(of: "_", with: " ").capitalized)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 4)

        VStack(alignment: .trailing, spacing: AppTheme.Space.xxxs) {
          Text("\(Int(ingredient.calories))")
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
            + Text(" kcal")
            .font(.system(.caption2, design: .rounded, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary)

          macroBar(ingredient: ingredient)
        }

        if isMultiSelect {
          Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(isChosen ? AppTheme.sage : AppTheme.oat.opacity(0.5))
            .symbolEffect(
              .bounce,
              options: reduceMotion ? .nonRepeating : .default,
              value: isChosen
            )
        }
      }
      .padding(.vertical, AppTheme.Space.sm)
      .contentShape(Rectangle())
    }
    .buttonStyle(IngredientRowButtonStyle())
    .opacity(reduceMotion ? 1 : 1)
    .animation(
      reduceMotion
        ? nil
        : AppMotion.cardSpring.delay(Double(min(index, 12)) * 0.025),
      value: resultsRevealToken
    )
  }

  // MARK: - Ingredient Icon Badge

  private func ingredientIcon(_ ingredient: Ingredient) -> some View {
    let (symbol, tint) = iconInfo(for: ingredient)

    return Image(systemName: symbol)
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: 36, height: 36)
      .background(
        FLOrganicBlob(seed: ingredient.name.hashValue)
          .fill(tint.opacity(0.12))
      )
      .overlay(
        FLOrganicBlob(seed: ingredient.name.hashValue)
          .stroke(tint.opacity(0.20), lineWidth: 0.8)
      )
  }

  private func iconInfo(for ingredient: Ingredient) -> (symbol: String, tint: Color) {
    let group = ingredient.spriteGroup?.lowercased() ?? ""
    switch group {
    case "protein":
      return ("fork.knife", AppTheme.accent)
    case "vegetable":
      return ("leaf.fill", AppTheme.sage)
    case "fruit":
      return ("leaf.circle.fill", Color(red: 0.82, green: 0.52, blue: 0.32))
    case "grain_legume":
      return ("takeoutbag.and.cup.and.straw.fill", AppTheme.oat)
    case "dairy_egg":
      return ("drop.fill", Color(red: 0.62, green: 0.68, blue: 0.78))
    case "oil_fat":
      return ("drop.triangle.fill", AppTheme.oat)
    case "herb_spice":
      return ("sparkles", AppTheme.sage)
    case "nut_seed":
      return ("smallcircle.filled.circle", Color(red: 0.68, green: 0.56, blue: 0.42))
    case "condiment":
      return ("line.3.horizontal.decrease.circle.fill", AppTheme.dustyRose)
    default:
      return ("square.grid.2x2", AppTheme.textSecondary)
    }
  }

  // MARK: - Macro Proportion Bar

  private func macroBar(ingredient: Ingredient) -> some View {
    let total = max(ingredient.protein + ingredient.carbs + ingredient.fat, 0.1)
    let pFrac = ingredient.protein / total
    let cFrac = ingredient.carbs / total
    let fFrac = ingredient.fat / total

    return GeometryReader { geo in
      let w = geo.size.width
      HStack(spacing: 1) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(AppTheme.chartProtein)
          .frame(width: max(2, w * pFrac))
        RoundedRectangle(cornerRadius: 1.5)
          .fill(AppTheme.chartCarbs)
          .frame(width: max(2, w * cFrac))
        RoundedRectangle(cornerRadius: 1.5)
          .fill(AppTheme.chartFat)
          .frame(width: max(2, w * fFrac))
      }
    }
    .frame(width: 48, height: 4)
    .clipShape(Capsule())
  }

  // MARK: - Empty Browse State

  private var emptyBrowseState: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Spacer()

      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: "tray")
          .font(.system(size: 28, weight: .light))
          .foregroundStyle(AppTheme.oat.opacity(0.6))

        VStack(spacing: AppTheme.Space.xxs) {
          Text("No ingredients available")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)

          Text("Try rebuilding the bundled ingredient catalog.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, AppTheme.Space.page)
  }

  // MARK: - No Results State

  private var noResultsState: some View {
    VStack(spacing: AppTheme.Space.lg) {
      Spacer()

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

          Text("Try a shorter name, a common alias, or check spelling.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, AppTheme.Space.page)
  }

  // MARK: - Search Logic

  private func runSearch(query: String, bypassDebounce: Bool) async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    if !bypassDebounce {
      try? await Task.sleep(for: .milliseconds(220))
      guard !Task.isCancelled else { return }
      if trimmed != searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
        return
      }
    }

    isLoading = true
    defer { isLoading = false }

    if trimmed.isEmpty {
      if !seedIngredients.isEmpty {
        results = seedIngredients
      } else {
        results = (try? deps.ingredientRepository.fetchAll()) ?? []
      }
    } else {
      results = (try? deps.ingredientRepository.search(query: trimmed, limit: 120)) ?? []
    }

    resultsRevealToken = UUID()
  }

  // MARK: - Selection Helpers

  private func isSelected(_ id: Int64) -> Bool {
    selectedIDs?.wrappedValue.contains(id) ?? false
  }

  private func toggleSelection(_ id: Int64) {
    guard var current = selectedIDs?.wrappedValue else { return }
    if current.contains(id) {
      current.remove(id)
    } else {
      current.insert(id)
    }
    selectedIDs?.wrappedValue = current
  }
}

// MARK: - Row Button Style

private struct IngredientRowButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        configuration.isPressed
          ? AppTheme.oat.opacity(0.10)
          : Color.clear,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(reduceMotion ? nil : AppMotion.press, value: configuration.isPressed)
  }
}
