import SwiftUI
import FLFeatureLogic

/// Grouped-shortage presentation for a weekly plan.
///
/// Renders the planner's grouped shortage rows (`WeeklyPlanResult.shortages`):
/// one card per (ingredient, category), with the resolution the plan assumes —
/// not enough on hand, missing entirely, unconfirmed estimate, or a substitute
/// the plan cooks instead. Quantities come straight from the planner; this view
/// adds no arithmetic of its own.
///
/// The planner reports ingredient IDs, not names. Pass `ingredientName` to
/// resolve IDs against the household catalog; the fallback keeps the card
/// honest (raw ID) rather than guessing a label.
struct WeeklyPlanShortageView: View {
  let shortages: [WeeklyPlanShortage]
  var ingredientName: (Int64) -> String = { "#\($0)" }
  var recipeTitle: (Int64) -> String? = { _ in nil }

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
      FLSectionHeader(
        "Shopping notes",
        subtitle: "What the plan assumes beyond what's confirmed in your kitchen",
        icon: "basket")

      if shortages.isEmpty {
        Text("Everything this plan cooks is covered by confirmed stock.")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      } else {
        // Identity by index: the same ingredient can legitimately appear in
        // two categories (a substitution note and its own shortfall).
        ForEach(shortages.indices, id: \.self) { index in
          shortageCard(shortages[index])
        }
      }
    }
  }

  @ViewBuilder
  private func shortageCard(_ shortage: WeeklyPlanShortage) -> some View {
    FLCard(tone: shortage.category == .substituted ? .normal : .warning) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: iconName(shortage.category))
          .foregroundStyle(AppTheme.accent)
          .font(.system(size: 14, weight: .semibold))
        Text(ingredientName(shortage.ingredientId))
          .font(AppTheme.Typography.displayCaption)
          .foregroundStyle(AppTheme.textPrimary)
        Spacer()
        Text(categoryLabel(shortage.category))
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }

      Text(detail(shortage))
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)

      if let substitute = shortage.substituteIngredientId {
        Text("Plan cooks \(ingredientName(substitute)) instead.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textPrimary)
      }

      let titles = shortage.affectedRecipeIds.compactMap(recipeTitle)
      if !titles.isEmpty {
        Text("For \(titles.joined(separator: ", "))")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel(shortage))
  }

  private func detail(_ shortage: WeeklyPlanShortage) -> String {
    let needed = formatted(shortage.neededGrams)
    switch shortage.category {
    case .missing:
      return "Plan needs \(needed), none in the kitchen."
    case .shortQuantity:
      let available = formatted(shortage.availableGrams)
      let shortfall = formatted(shortage.shortfallGrams)
      return "Plan needs \(needed), \(available) confirmed — \(shortfall) to buy."
    case .unknownAmount:
      return "Only an unconfirmed estimate is on hand; it cannot back the plan's \(needed)."
    case .substituted:
      return "Plan assumes \(needed) covered by a substitute."
    }
  }

  private func categoryLabel(_ category: WeeklyPlanShortageCategory) -> String {
    switch category {
    case .missing: return "Missing"
    case .shortQuantity: return "Not enough"
    case .unknownAmount: return "Unconfirmed"
    case .substituted: return "Substituted"
    }
  }

  private func iconName(_ category: WeeklyPlanShortageCategory) -> String {
    switch category {
    case .missing: return "cart.badge.plus"
    case .shortQuantity: return "scale.3d"
    case .unknownAmount: return "questionmark.circle"
    case .substituted: return "arrow.triangle.2.circlepath"
    }
  }

  private func accessibilityLabel(_ shortage: WeeklyPlanShortage) -> Text {
    Text("\(ingredientName(shortage.ingredientId)), \(categoryLabel(shortage.category)). \(detail(shortage))")
  }

  /// Grams for kitchen amounts: whole grams under a kilogram, one decimal of
  /// kg above — matching how the rest of the app presents produce weights.
  private func formatted(_ grams: Double) -> String {
    if grams >= 1_000 {
      return String(format: "%.1f kg", grams / 1_000)
    }
    return String(format: "%.0f g", grams)
  }
}
