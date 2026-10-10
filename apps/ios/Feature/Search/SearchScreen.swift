import SwiftUI

// MARK: - View Model

/// Drives the unified search screen: debounced queries against the shared
/// search index, kind filters, and live resolution of a tapped result.
@MainActor
@Observable
final class SearchScreenModel {
  var query = ""
  var kindFilter: SearchKindFilter = .all
  private(set) var results: [SearchHit] = []
  private(set) var isSearching = false

  /// Monotonic token so a slow query cannot overwrite newer results.
  private var searchGeneration = 0

  func runSearch(using service: SearchIndexService) {
    searchGeneration += 1
    let generation = searchGeneration
    let query = query
    let kinds = kindFilter.recordKinds

    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      results = []
      isSearching = false
      return
    }

    isSearching = true
    Task.detached(priority: .userInitiated) { [weak self] in
      // Debounce before touching the index so typing stays cheap.
      try? await Task.sleep(for: .milliseconds(180))
      let hits = (try? service.search(query, kinds: kinds)) ?? []
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self, generation == self.searchGeneration else { return }
        self.results = hits
        self.isSearching = false
      }
    }
  }
}

// MARK: - Kind Filter

enum SearchKindFilter: CaseIterable, Sendable {
  case all
  case inventory
  case ingredients
  case recipes
  case journal

  var label: String {
    switch self {
    case .all: "All"
    case .inventory: "In Stock"
    case .ingredients: "Ingredients"
    case .recipes: "Recipes"
    case .journal: "Journal"
    }
  }

  var recordKinds: Set<SearchRecordKind>? {
    switch self {
    case .all: nil
    case .inventory: [.kitchenInventory]
    case .ingredients: [.kitchenIngredient]
    case .recipes: [.recipe]
    case .journal: [.journal]
    }
  }
}

// MARK: - Screen

struct SearchScreen: View {
  @EnvironmentObject var deps: AppDependencies
  @State private var model = SearchScreenModel()
  @State private var selectedDetail: SearchResultDetail?

  var body: some View {
    VStack(spacing: 0) {
      kindFilterBar
      resultList
    }
    .navigationTitle("Search")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(
      text: Binding(
        get: { model.query },
        set: { newValue in
          model.query = newValue
          model.runSearch(using: deps.searchIndexService)
        }
      ),
      placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Kitchen, recipes, journal"
    )
    .sheet(item: $selectedDetail) { detail in
      SearchResultDetailView(detail: detail)
        .presentationDetents([.medium, .large])
    }
  }

  private var kindFilterBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: AppTheme.Space.sm) {
        ForEach(SearchKindFilter.allCases, id: \.self) { filter in
          Button {
            model.kindFilter = filter
            model.runSearch(using: deps.searchIndexService)
          } label: {
            Text(filter.label)
              .font(AppTheme.Typography.labelSmall)
              .padding(.horizontal, AppTheme.Space.md)
              .padding(.vertical, AppTheme.Space.xs)
              .background(
                model.kindFilter == filter ? AppTheme.accent : AppTheme.surface,
                in: Capsule()
              )
              .foregroundStyle(model.kindFilter == filter ? .white : AppTheme.textSecondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.vertical, AppTheme.Space.sm)
    }
  }

  private var resultList: some View {
    List {
      if model.results.isEmpty && !model.isSearching && !model.query.isEmpty {
        ContentUnavailableView.search(text: Text(model.query))
      } else {
        ForEach(model.results) { hit in
          Button {
            resolve(hit: hit)
          } label: {
            SearchResultRow(hit: hit)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .listStyle(.plain)
  }

  /// Resolves the hit against the live repositories before navigating; a
  /// deleted record resolves to nothing and is dropped from the index by the
  /// engine on the next query.
  private func resolve(hit: SearchHit) {
    guard let target = try? deps.searchIndexService.resolve(hit) else { return }
    selectedDetail = SearchResultDetail(hit: hit, target: target)
  }
}

// MARK: - Rows

private struct SearchResultRow: View {
  let hit: SearchHit

  var body: some View {
    HStack(spacing: AppTheme.Space.md) {
      Image(systemName: iconName)
        .foregroundStyle(AppTheme.accent)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(hit.title)
          .font(AppTheme.Typography.bodyLarge)
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(1)
        Text(hit.subtitle ?? kindLabel)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, AppTheme.Space.xxs)
    .contentShape(Rectangle())
  }

  private var iconName: String {
    switch hit.canonicalID.kind {
    case .kitchenIngredient: "leaf"
    case .kitchenInventory: "refrigerator"
    case .recipe: "book.closed"
    case .journal: "fork.knife"
    }
  }

  private var kindLabel: String {
    switch hit.canonicalID.kind {
    case .kitchenIngredient: "Ingredient"
    case .kitchenInventory: "In stock"
    case .recipe: "Recipe"
    case .journal: "Journal entry"
    }
  }
}

// MARK: - Detail

/// A tapped result that resolved against the live repositories. Resolved
/// targets carry the record itself, so the sheet never reads the index.
struct SearchResultDetail: Identifiable {
  let hit: SearchHit
  let target: SearchResolvedTarget

  var id: String { hit.id }
}

private struct SearchResultDetailView: View {
  let detail: SearchResultDetail

  var body: some View {
    switch detail.target {
    case .kitchenIngredient(let ingredient):
      rows(
        title: ingredient.name,
        subtitle: "Ingredient catalog"
      )
    case .kitchenInventory(let inventory):
      rows(
        title: inventory.ingredientName,
        subtitle:
          "\(inventory.storageLocation.rawValue) · \(Int(inventory.totalRemainingGrams.rounded())) g in stock"
      )
    case .recipe(let recipe):
      rows(
        title: recipe.title,
        subtitle: "Recipe · \(recipe.timeMinutes) min · serves \(recipe.servings)"
      )
    case .journal(let entry):
      rows(
        title: entry.recipeTitle,
        subtitle: "Cooked \(entry.cookedAt.formatted(date: .abbreviated, time: .omitted))"
          + (entry.rating.map { " · rated \($0)" } ?? "")
      )
    }
  }

  private func rows(title: String, subtitle: String) -> some View {
    VStack(spacing: AppTheme.Space.lg) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 34, weight: .medium))
        .foregroundStyle(AppTheme.accent)
        .padding(.top, AppTheme.Space.xl)

      VStack(spacing: AppTheme.Space.xs) {
        Text(title)
          .font(AppTheme.Typography.displaySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .multilineTextAlignment(.center)
        Text(subtitle)
          .font(AppTheme.Typography.bodyLarge)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }

      Spacer()
    }
    .padding(.horizontal, AppTheme.Space.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
