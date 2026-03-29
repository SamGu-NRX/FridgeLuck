import SwiftUI

/// Horizontal ingredient chips; single- or multi-select.
struct FLIngredientChipScroll: View {
  let ingredients: [Ingredient]
  let selectedIDs: Set<Int64>
  let isMultiSelect: Bool
  let onTap: (Ingredient) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: AppTheme.Space.xs) {
        ForEach(ingredients, id: \.id) { ingredient in
          if let id = ingredient.id {
            chipView(ingredient, id: id)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
    }
  }

  // MARK: - Chip

  private func chipView(_ ingredient: Ingredient, id: Int64) -> some View {
    let isSelected = selectedIDs.contains(id)

    return Button {
      onTap(ingredient)
    } label: {
      HStack(spacing: AppTheme.Space.xxs) {
        ingredientChipIcon(ingredient)

        Text(ingredient.displayName)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
          .lineLimit(1)

        if isMultiSelect, isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .padding(.horizontal, AppTheme.Space.sm)
      .frame(height: 32)
      .background(
        isSelected
          ? AppTheme.accent
          : AppTheme.surface,
        in: Capsule()
      )
      .overlay(
        Capsule()
          .stroke(
            isSelected ? AppTheme.accent : AppTheme.oat.opacity(0.30),
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
    .animation(reduceMotion ? nil : AppMotion.chipToggle, value: isSelected)
  }

  // MARK: - Chip Icon

  private func ingredientChipIcon(_ ingredient: Ingredient) -> some View {
    let (symbol, tint) = iconInfo(for: ingredient)

    return Image(systemName: symbol)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: 18, height: 18)
      .background(tint.opacity(0.15), in: Circle())
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
}
