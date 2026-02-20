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
      VStack(spacing: AppTheme.Space.sm) {
        if isMultiSelect {
          multiSelectSummary
            .padding(.horizontal, AppTheme.Space.md)
            .padding(.top, AppTheme.Space.xs)
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        Group {
          if results.isEmpty, !isLoading {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              FLEmptyState(
                title: "No ingredients available",
                message: "Try rebuilding the bundled ingredient catalog.",
                systemImage: "tray"
              )
              .padding()
            } else {
              ContentUnavailableView.search(text: searchText)
            }
          } else {
            List(results, id: \.id) { ingredient in
              ingredientRow(ingredient)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
      .overlay(alignment: .top) {
        if isLoading {
          ProgressView()
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.xs)
            .background(AppTheme.surface, in: Capsule())
            .overlay(
              Capsule()
                .stroke(AppTheme.textSecondary.opacity(0.16), lineWidth: 1)
            )
            .padding(.top, AppTheme.Space.xs)
        }
      }
    }
    .flPageBackground()
    .animation(reduceMotion ? nil : AppMotion.gentle, value: selectedIDs?.wrappedValue.count ?? 0)
  }

  private var multiSelectSummary: some View {
    let count = selectedIDs?.wrappedValue.count ?? 0

    return FLCard(tone: .warm) {
      HStack(spacing: AppTheme.Space.sm) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          Text("\(count) selected")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
          Text("Search official names and aliases.")
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer()
        FLSecondaryButton("Clear", systemImage: "xmark.circle", isEnabled: count > 0) {
          guard var current = selectedIDs?.wrappedValue else { return }
          current.removeAll()
          selectedIDs?.wrappedValue = current
        }
        .frame(maxWidth: 120)
      }
    }
  }

  @ViewBuilder
  private func ingredientRow(_ ingredient: Ingredient) -> some View {
    if let id = ingredient.id {
      Button {
        if isMultiSelect {
          toggleSelection(id)
        } else {
          onPickSingle?(ingredient)
          dismiss()
        }
      } label: {
        FLCard(tone: .normal) {
          HStack(spacing: AppTheme.Space.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
              Text(ingredient.displayName)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
              if let description = ingredient.description, !description.isEmpty {
                Text(description)
                  .font(.caption)
                  .foregroundStyle(AppTheme.textSecondary)
                  .lineLimit(2)
              }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: AppTheme.Space.xxs) {
              Text("\(Int(ingredient.calories)) kcal")
                .font(.caption.bold())
                .foregroundStyle(AppTheme.textPrimary)
              Text("per 100g")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
            }

            if isMultiSelect {
              Image(systemName: isSelected(id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected(id) ? AppTheme.positive : AppTheme.textSecondary)
            }
          }
        }
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
    }
  }

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
      return
    }

    results = (try? deps.ingredientRepository.search(query: trimmed, limit: 120)) ?? []
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
}
