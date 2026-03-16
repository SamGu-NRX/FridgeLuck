import SwiftUI

struct AllergenPickerView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let catalog: AllergenCatalogIndex
  @Binding var selectedIDs: Set<Int64>

  @State private var searchText = ""
  @State private var includeFullCatalog = false
  @State private var showOnlySelected = false

  private var normalizedSearchText: String {
    AllergenSupport.normalizedQuery(searchText)
  }

  private var selectedIngredients: [Ingredient] {
    catalog.selectedIngredients(from: selectedIDs)
  }

  private var visibleSections: [AllergenCatalogSection] {
    let baseSections = catalog.sections(
      matching: normalizedSearchText,
      includeAllIngredients: includeFullCatalog
    )

    guard showOnlySelected else { return baseSections }

    return baseSections.compactMap { section in
      let ingredients = section.ingredients.filter { selectedIDs.contains($0.id) }
      guard !ingredients.isEmpty else { return nil }
      return AllergenCatalogSection(id: section.id, title: section.title, ingredients: ingredients)
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: AppTheme.Space.md, pinnedViews: [.sectionHeaders])
        {
          Section {
            guidanceCard
            modeControls

            if !selectedIngredients.isEmpty {
              selectedIngredientsBlock
            }

            if visibleSections.isEmpty {
              emptyState
            } else {
              ForEach(visibleSections) { section in
                sectionBlock(section)
              }
            }
          } header: {
            stickyTopBar
          }
        }
        .padding(.horizontal, AppTheme.Space.md)
        .padding(.top, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.xl)
      }
      .navigationTitle("Refine Specific Ingredients")
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
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Specific allergen details")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text("Search exact ingredients instead of broad allergen groups.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()

        Text("\(selectedIDs.count) selected")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
      }

      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(AppTheme.textSecondary)
        TextField("Search whey, tahini, miso, cod...", text: $searchText)
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
    .background(AppTheme.bg.opacity(0.96))
  }

  private var guidanceCard: some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        Text("The Big 10 cards already handle the common cases.")
          .font(.system(.subheadline, design: .serif, weight: .semibold))
          .foregroundStyle(AppTheme.textPrimary)

        Text(
          "Use this screen only when you want finer control over exact catalog ingredients. It is best for ingredients like whey, tahini, miso, cod, or mayonnaise."
        )
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)

        FlowLayout(spacing: AppTheme.Space.xs) {
          exampleChip("Whey")
          exampleChip("Tahini")
          exampleChip("Miso")
          exampleChip("Cod")
          exampleChip("Mayonnaise")
        }
      }
    }
  }

  private var modeControls: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(spacing: AppTheme.Space.xs) {
        modeButton(
          title: "Suggested",
          subtitle: "Likely allergen ingredients",
          isActive: !includeFullCatalog
        ) {
          withAnimation(reduceMotion ? nil : AppMotion.standard) {
            includeFullCatalog = false
          }
        }

        modeButton(
          title: "Full Catalog",
          subtitle: "Browse every ingredient",
          isActive: includeFullCatalog
        ) {
          withAnimation(reduceMotion ? nil : AppMotion.standard) {
            includeFullCatalog = true
          }
        }
      }

      Toggle(isOn: $showOnlySelected.animation(reduceMotion ? nil : AppMotion.colorTransition)) {
        Text("Show selected ingredients only")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .toggleStyle(.switch)
      .tint(AppTheme.accent)
    }
  }

  private var selectedIngredientsBlock: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("CURRENTLY SELECTED")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.2)

      FlowLayout(spacing: AppTheme.Space.xs) {
        ForEach(Array(selectedIngredients.prefix(24)), id: \.id) { ingredient in
          Text(ingredient.displayName)
            .font(AppTheme.Typography.bodySmall)
            .padding(.horizontal, AppTheme.Space.sm)
            .padding(.vertical, AppTheme.Space.chipVertical)
            .background(
              Capsule(style: .continuous)
                .fill(AppTheme.accent.opacity(0.12))
            )
            .overlay(
              Capsule(style: .continuous)
                .stroke(AppTheme.accent.opacity(0.16), lineWidth: 1)
            )
        }
      }
    }
  }

  private var emptyState: some View {
    FLEmptyState(
      title: showOnlySelected ? "No selected ingredients in this view" : "No ingredients found",
      message: showOnlySelected
        ? "Try turning off the selected-only filter or search for something else."
        : "Try a broader search term or switch between Suggested and Full Catalog.",
      systemImage: showOnlySelected ? "line.3.horizontal.decrease.circle" : "magnifyingglass"
    )
  }

  private func modeButton(
    title: String,
    subtitle: String,
    isActive: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(title)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textPrimary)
        Text(subtitle)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.sm)
      .background(
        isActive ? AppTheme.accent.opacity(0.14) : AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(isActive ? AppTheme.accent : AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
      .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isActive)
    }
    .buttonStyle(.plain)
  }

  private func exampleChip(_ title: String) -> some View {
    Text(title)
      .font(AppTheme.Typography.labelSmall)
      .foregroundStyle(AppTheme.textSecondary)
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.xxs)
      .background(
        Capsule(style: .continuous)
          .fill(AppTheme.surface)
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(AppTheme.oat.opacity(0.2), lineWidth: 1)
      )
  }

  private func sectionBlock(_ section: AllergenCatalogSection) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      HStack {
        Text(section.title)
          .font(.system(.subheadline, design: .serif, weight: .semibold))
          .foregroundStyle(AppTheme.textPrimary)
        Spacer()
        Text("\(section.ingredients.count)")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      ForEach(section.ingredients) { item in
        allergenRow(item)
      }
    }
  }

  private func allergenRow(_ item: AllergenIndexedIngredient) -> some View {
    let selected = selectedIDs.contains(item.id)

    return Button {
      withAnimation(reduceMotion ? nil : AppMotion.chipReflow) {
        if selected {
          selectedIDs.remove(item.id)
        } else {
          selectedIDs.insert(item.id)
        }
      }
    } label: {
      FLCard {
        HStack(spacing: AppTheme.Space.sm) {
          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text(item.displayName)
              .font(.system(.subheadline, design: .serif, weight: .semibold))
              .foregroundStyle(AppTheme.textPrimary)

            HStack(spacing: AppTheme.Space.xxs) {
              if let category = item.ingredient.categoryLabel, !category.isEmpty {
                Text(category.replacingOccurrences(of: "_", with: " ").capitalized)
              }

              if includeFullCatalog, item.group == nil {
                Text("Not auto-matched")
              }
            }
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
          }

          Spacer()

          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? AppTheme.positive : AppTheme.textSecondary)
            .animation(reduceMotion ? nil : AppMotion.colorTransition, value: selected)
        }
      }
    }
    .buttonStyle(.plain)
  }
}
