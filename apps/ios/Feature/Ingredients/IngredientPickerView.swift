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

  @State private var favorites: [Ingredient] = []
  @State private var recents: [Ingredient] = []
  @State private var commonIngredients: [Ingredient] = []
  @State private var isExpanded = false
  @State private var groupedIngredients: [(letter: String, ingredients: [Ingredient])] = []
  @State private var favoriteIDs: Set<Int64> = []

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
  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

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

        ZStack {
          if isSearching {
            searchResultsView
          } else if isExpanded {
            expandedListView
          } else {
            smartSectionsView
          }
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search ingredients")
      .task {
        await loadSmartSections()
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
    .animation(reduceMotion ? nil : AppMotion.gentle, value: isExpanded)
    .animation(reduceMotion ? nil : AppMotion.gentle, value: isSearching)
  }

  // MARK: - Multi-Select Summary

  private var multiSelectSummary: some View {
    let count = selectedIDs?.wrappedValue.count ?? 0

    return HStack(spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: "checkmark.seal.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(count > 0 ? AppTheme.sage : AppTheme.textSecondary)
          .animation(reduceMotion ? nil : AppMotion.colorTransition, value: count > 0)

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

  // MARK: - Smart Sections

  private var smartSectionsView: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        if !favorites.isEmpty {
          sectionHeader(title: "Favorites", icon: "heart.fill", tint: AppTheme.dustyRose)
          FLIngredientChipScroll(
            ingredients: favorites,
            selectedIDs: selectedIDs?.wrappedValue ?? [],
            isMultiSelect: isMultiSelect
          ) { ingredient in
            handleIngredientTap(ingredient)
          }
        }

        if !recents.isEmpty {
          sectionHeader(title: "Recent", icon: "clock.arrow.circlepath", tint: AppTheme.sage)
          FLIngredientChipScroll(
            ingredients: recents,
            selectedIDs: selectedIDs?.wrappedValue ?? [],
            isMultiSelect: isMultiSelect
          ) { ingredient in
            handleIngredientTap(ingredient)
          }
        }

        if !commonIngredients.isEmpty {
          sectionHeader(title: "Common", icon: "star.fill", tint: AppTheme.oat)

          LazyVStack(spacing: 0) {
            ForEach(Array(commonIngredients.enumerated()), id: \.element.id) { index, ingredient in
              if let id = ingredient.id {
                ingredientRow(ingredient, id: id, index: index)

                if index < commonIngredients.count - 1 {
                  rowDivider
                }
              }
            }
          }
          .padding(.horizontal, AppTheme.Space.page)
        }

        Button {
          Task {
            if groupedIngredients.isEmpty {
              groupedIngredients = (try? deps.ingredientRepository.fetchAllGrouped()) ?? []
            }
            isExpanded = true
          }
        } label: {
          HStack(spacing: AppTheme.Space.sm) {
            Image(systemName: "list.bullet")
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(AppTheme.accent)

            Text("Show all ingredients")
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.accent)

            Spacer()

            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(AppTheme.accent.opacity(0.6))
          }
          .padding(AppTheme.Space.md)
          .background(
            AppTheme.accent.opacity(0.06),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
              .stroke(AppTheme.accent.opacity(0.15), lineWidth: 1)
          )
        }
        .buttonStyle(FLPressableButtonStyle())
        .padding(.horizontal, AppTheme.Space.page)

        if favorites.isEmpty, recents.isEmpty, commonIngredients.isEmpty, !isLoading {
          emptyBrowseState
        }

        Spacer(minLength: AppTheme.Space.xxl)
      }
      .padding(.top, AppTheme.Space.sm)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  // MARK: - Expanded A-Z List View

  private var expandedListView: some View {
    let availableLetters = Set(groupedIngredients.map(\.letter))

    return HStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            Button {
              isExpanded = false
            } label: {
              HStack(spacing: AppTheme.Space.xs) {
                Image(systemName: "chevron.left")
                  .font(.system(size: 12, weight: .semibold))
                Text("Back to common")
                  .font(AppTheme.Typography.label)
              }
              .foregroundStyle(AppTheme.accent)
              .padding(.horizontal, AppTheme.Space.page)
              .padding(.vertical, AppTheme.Space.sm)
            }
            .buttonStyle(.plain)

            ForEach(groupedIngredients, id: \.letter) { group in
              Section {
                ForEach(Array(group.ingredients.enumerated()), id: \.element.id) {
                  index, ingredient in
                  if let id = ingredient.id {
                    ingredientRow(ingredient, id: id, index: index)

                    if index < group.ingredients.count - 1 {
                      rowDivider
                    }
                  }
                }
              } header: {
                Text(group.letter)
                  .font(.system(.caption, design: .rounded, weight: .bold))
                  .foregroundStyle(AppTheme.textSecondary)
                  .padding(.horizontal, AppTheme.Space.page)
                  .padding(.top, AppTheme.Space.md)
                  .padding(.bottom, AppTheme.Space.xxs)
                  .id("section_\(group.letter)")
              }
            }

            Spacer(minLength: AppTheme.Space.xxl)
          }
          .padding(.top, AppTheme.Space.xs)
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .trailing) {
          FLAlphabetScrubber(
            availableLetters: availableLetters,
            onLetterChanged: { letter in
              withAnimation(reduceMotion ? nil : AppMotion.quick) {
                proxy.scrollTo("section_\(letter)", anchor: .top)
              }
            }
          )
          .padding(.trailing, 2)
        }
      }
    }
  }

  // MARK: - Search Results View

  private var searchResultsView: some View {
    Group {
      if results.isEmpty, !isLoading {
        noResultsState
      } else {
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
    }
  }

  // MARK: - Section Header

  private func sectionHeader(title: String, icon: String, tint: Color) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)

      Text(title.uppercased())
        .font(.system(.caption2, design: .rounded, weight: .bold))
        .foregroundStyle(AppTheme.textSecondary)
        .tracking(0.8)

      Spacer()
    }
    .padding(.horizontal, AppTheme.Space.page)
    .padding(.top, AppTheme.Space.xs)
  }

  // MARK: - Ingredient Row

  private func ingredientRow(_ ingredient: Ingredient, id: Int64, index: Int) -> some View {
    let isChosen = isMultiSelect ? isSelected(id) : false
    let isFavorited = favoriteIDs.contains(id)

    return Button {
      handleIngredientTap(ingredient)
    } label: {
      HStack(spacing: AppTheme.Space.sm) {
        ingredientIcon(ingredient)

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          HStack(spacing: AppTheme.Space.xxs) {
            Text(ingredient.displayName)
              .font(.system(.subheadline, design: .serif, weight: .semibold))
              .foregroundStyle(AppTheme.textPrimary)
              .lineLimit(1)

            if isFavorited {
              Image(systemName: "heart.fill")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.dustyRose)
            }
          }

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
          Text("\(Int(ingredient.calories)) kcal")
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)

          macroBar(ingredient: ingredient)
        }

        if isMultiSelect {
          Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(isChosen ? AppTheme.sage : AppTheme.oat.opacity(0.5))
            .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isChosen)
            .symbolEffect(
              .bounce,
              options: reduceMotion ? .nonRepeating : .default,
              value: isChosen
            )
        }
      }
      .padding(.vertical, AppTheme.Space.sm)
      .padding(.horizontal, AppTheme.Space.page)
      .contentShape(Rectangle())
    }
    .buttonStyle(IngredientRowButtonStyle())
    .contextMenu {
      Button {
        toggleFavorite(id)
      } label: {
        Label(
          isFavorited ? "Remove from Favorites" : "Add to Favorites",
          systemImage: isFavorited ? "heart.slash" : "heart"
        )
      }
    }
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

  // MARK: - Row Divider

  private var rowDivider: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.18))
      .frame(height: 1)
      .padding(.leading, 52 + AppTheme.Space.page)
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

  // MARK: - Data Loading

  private func loadSmartSections() async {
    isLoading = true
    defer { isLoading = false }

    favorites = (try? deps.ingredientRepository.fetchFavorites()) ?? []
    favoriteIDs = Set(favorites.compactMap(\.id))
    recents = (try? deps.ingredientRepository.fetchRecentlyUsed(limit: 15)) ?? []
    commonIngredients = (try? deps.ingredientRepository.fetchCommon(limit: 40)) ?? []

    if !seedIngredients.isEmpty {
      commonIngredients = seedIngredients
    }
  }

  // MARK: - Search Logic

  private func runSearch(query: String, bypassDebounce: Bool) async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else {
      results = []
      return
    }

    if !bypassDebounce {
      try? await Task.sleep(for: .milliseconds(220))
      guard !Task.isCancelled else { return }
      if trimmed != searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
        return
      }
    }

    isLoading = true
    defer { isLoading = false }

    results = (try? deps.ingredientRepository.search(query: trimmed, limit: 120)) ?? []
    resultsRevealToken = UUID()
  }

  // MARK: - Selection Helpers

  private func handleIngredientTap(_ ingredient: Ingredient) {
    guard let id = ingredient.id else { return }
    if isMultiSelect {
      toggleSelection(id)
    } else {
      onPickSingle?(ingredient)
      dismiss()
    }
  }

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

  // MARK: - Favorites

  private func toggleFavorite(_ id: Int64) {
    do {
      let isNowFavorited = try deps.ingredientRepository.toggleFavorite(ingredientId: id)
      if isNowFavorited {
        favoriteIDs.insert(id)
      } else {
        favoriteIDs.remove(id)
      }
      Task {
        favorites = (try? deps.ingredientRepository.fetchFavorites()) ?? []
      }
    } catch {}
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
