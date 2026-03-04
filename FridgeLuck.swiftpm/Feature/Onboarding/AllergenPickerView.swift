import SwiftUI

struct AllergenPickerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let ingredients: [Ingredient]
  @Binding var selectedIDs: Set<Int64>

  @State private var searchText = ""
  @State private var showAllIngredients = false

  private enum Layout {
    static let groupChipHeight: CGFloat = 92
  }

  private var baseIngredients: [Ingredient] {
    if showAllIngredients {
      return ingredients.sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
      .filter { $0.id != nil }
    }

    return AllergenSupport.relevantIngredients(in: ingredients)
  }

  private var filteredIngredients: [Ingredient] {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return baseIngredients }

    return
      ingredients
      .filter { ingredient in
        ingredient.id != nil && AllergenSupport.searchableText(for: ingredient).contains(trimmed)
      }
      .sorted { lhs, rhs in
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
  }

  private var groupedIngredients: [(title: String, ingredients: [Ingredient])] {
    let grouped = Dictionary(grouping: filteredIngredients) { ingredient -> String in
      AllergenSupport.group(for: ingredient)?.title ?? "Other"
    }

    var ordered: [(String, [Ingredient])] = []

    for group in AllergenSupport.groups {
      if let items = grouped[group.title], !items.isEmpty {
        ordered.append((group.title, items))
      }
    }

    if let other = grouped["Other"], !other.isEmpty {
      ordered.append(("Other", other))
    }

    return ordered
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: AppTheme.Space.md, pinnedViews: [.sectionHeaders])
        {
          Section {
            commonAllergenGroups
            displayModeToggle
          } header: {
            stickyTopBar
          }

          if groupedIngredients.isEmpty {
            FLEmptyState(
              title: "No ingredients found",
              message: "Try a broader search term.",
              systemImage: "magnifyingglass"
            )
          } else {
            ForEach(groupedIngredients, id: \.title) { section in
              sectionBlock(title: section.title, ingredients: section.ingredients)
            }
          }
        }
        .padding(.horizontal, AppTheme.Space.md)
        .padding(.top, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.xl)
      }
      .navigationTitle("Select Allergens")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
      }
      .flPageBackground()
    }
  }

  private var stickyTopBar: some View {
    VStack(spacing: AppTheme.Space.sm) {
      HStack {
        Text("Common Allergens")
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
        Spacer()
        Text("\(selectedIDs.count) selected")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
      }

      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(AppTheme.textSecondary)
        TextField("Search allergens or ingredients", text: $searchText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
      }
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.sm)
      .background(
        AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.top, AppTheme.Space.sm)
    .padding(.bottom, AppTheme.Space.sm)
    .background(AppTheme.bg.opacity(0.95))
  }

  private var commonAllergenGroups: some View {
    FLCard(tone: .warm) {
      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: AppTheme.Space.xs),
          GridItem(.flexible(), spacing: AppTheme.Space.xs),
        ],
        spacing: AppTheme.Space.xs
      ) {
        ForEach(AllergenSupport.groups) { group in
          let ids = AllergenSupport.matchingIDs(for: group, in: ingredients)
          let selectedCount = selectedIDs.intersection(ids).count
          let isFullySelected = !ids.isEmpty && selectedCount == ids.count
          let isPartiallySelected = selectedCount > 0 && !isFullySelected
          let isSelected = isFullySelected || isPartiallySelected

          Button {
            toggleGroup(group)
          } label: {
            HStack(spacing: AppTheme.Space.xs) {
              Image(systemName: group.systemImage)
              VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
                Text(group.title)
                  .font(AppTheme.Typography.label)
                  .lineLimit(1)
                  .foregroundStyle(AppTheme.textPrimary)
                Text(isSelected ? "\(selectedCount) selected" : group.subtitle)
                  .font(AppTheme.Typography.labelSmall)
                  .lineLimit(2)
                  .multilineTextAlignment(.leading)
                  .foregroundStyle(AppTheme.textSecondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .frame(minHeight: 34, alignment: .topLeading)
              Spacer(minLength: 4)
              Image(
                systemName: isFullySelected
                  ? "checkmark.circle.fill" : (isPartiallySelected ? "minus.circle.fill" : "circle")
              )
            }
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.sm)
            .frame(
              maxWidth: .infinity, minHeight: Layout.groupChipHeight,
              maxHeight: Layout.groupChipHeight, alignment: .leading
            )
            .background(
              isSelected ? AppTheme.accent.opacity(0.14) : AppTheme.surface,
              in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
            )
            .overlay(
              RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .stroke(
                  isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.25), lineWidth: 1)
            )
            .opacity(ids.isEmpty ? 0.75 : 1)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(ids.isEmpty)
        }
      }
    }
  }

  private var displayModeToggle: some View {
    HStack {
      Button {
        withAnimation(reduceMotion ? nil : AppMotion.standard) {
          showAllIngredients.toggle()
        }
      } label: {
        Label(
          showAllIngredients ? "Showing all ingredients" : "Showing allergen-focused ingredients",
          systemImage: showAllIngredients
            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        )
        .font(AppTheme.Typography.label)
      }
      .buttonStyle(.plain)

      Spacer()
    }
    .foregroundStyle(AppTheme.textSecondary)
  }

  private func sectionBlock(title: String, ingredients: [Ingredient]) -> some View {
    let items = ingredients.compactMap { ingredient -> (id: Int64, ingredient: Ingredient)? in
      guard let id = ingredient.id else { return nil }
      return (id, ingredient)
    }

    return VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      HStack {
        Text(title)
          .font(.system(.subheadline, design: .serif, weight: .semibold))
          .foregroundStyle(AppTheme.textPrimary)
        Spacer()
        Text("\(items.count)")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      ForEach(items, id: \.id) { item in
        allergenRow(item.ingredient, id: item.id)
      }
    }
  }

  private func allergenRow(_ ingredient: Ingredient, id: Int64) -> some View {
    let selected = selectedIDs.contains(id)

    return Button {
      if selected {
        selectedIDs.remove(id)
      } else {
        selectedIDs.insert(id)
      }
    } label: {
      FLCard {
        HStack(spacing: AppTheme.Space.sm) {
          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text(ingredient.displayName)
              .font(.system(.subheadline, design: .serif, weight: .semibold))
              .foregroundStyle(AppTheme.textPrimary)

            if let category = ingredient.categoryLabel, !category.isEmpty {
              Text(category.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }

          Spacer()

          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? AppTheme.positive : AppTheme.textSecondary)
        }
      }
    }
    .buttonStyle(.plain)
  }

  private func toggleGroup(_ group: AllergenGroupDefinition) {
    let ids = AllergenSupport.matchingIDs(for: group, in: ingredients)
    guard !ids.isEmpty else { return }

    let selectedCount = selectedIDs.intersection(ids).count
    if selectedCount == ids.count {
      selectedIDs.subtract(ids)
    } else {
      selectedIDs.formUnion(ids)
    }
  }
}
