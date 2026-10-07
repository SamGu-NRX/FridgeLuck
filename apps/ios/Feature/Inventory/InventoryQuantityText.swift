import SwiftUI

/// Remaining amount for a Kitchen item. Photo-intake amounts are one-unit guesses, so they read
/// as "≈ 50g est." until the user sets an amount; measured or reviewed amounts read plainly.
struct InventoryQuantityText: View {
  let item: InventoryActiveItem
  let font: Font
  let color: Color

  @Environment(AppPreferencesStore.self) private var prefs

  private var weight: String { prefs.formatWeight(grams: item.totalRemainingGrams) }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xxxs) {
      Text(item.hasEstimatedQuantity ? "≈ \(weight)" : weight)
        .font(font)
        .foregroundStyle(color)
        .contentTransition(.numericText())

      if item.hasEstimatedQuantity {
        Text("est.")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      item.hasEstimatedQuantity ? "About \(weight), estimated from your photo" : weight
    )
  }
}
