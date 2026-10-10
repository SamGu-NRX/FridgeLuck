import SwiftUI

/// The editable ingredient plan behind a meal log. Display, the deduction preview and what
/// logging persists all read this one object, so correcting a quantity here changes what
/// the Kitchen loses. A corrected line is marked "Corrected by you" and keeps its absolute
/// grams when servings or portion change.
struct MealPlanEditorSection: View {
  /// The plan to show. Nil while the recipe is resolving or the plan failed to build.
  let plan: MealConsumptionPlan?
  /// The recipe the plan belongs to; nil while no recipe is chosen.
  let recipeId: Int64?
  var onLineEdited: (_ lineIndex: Int, _ grams: Double) -> Void = { _, _ in }

  @Environment(AppPreferencesStore.self) private var prefs

  /// A stale plan from the previous recipe is never shown for the new one.
  private var shownPlan: MealConsumptionPlan? {
    guard let recipeId, let plan, plan.recipeId == recipeId else { return nil }
    return plan
  }

  var body: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack {
          Text("Ingredient Plan")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
          Spacer()
          if let shownPlan, !shownPlan.lines.isEmpty {
            Text("\(shownPlan.lines.count) item\(shownPlan.lines.count == 1 ? "" : "s")")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
              .contentTransition(.numericText())
          }
        }

        if let shownPlan {
          if shownPlan.lines.isEmpty {
            Text("No ingredient amounts to show for this recipe.")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          } else {
            VStack(spacing: AppTheme.Space.xs) {
              ForEach(shownPlan.lines.indices, id: \.self) { index in
                planRow(index: index, line: shownPlan.lines[index])
                if index < shownPlan.lines.count - 1 {
                  Divider()
                }
              }
            }
            Text("Correct a quantity before logging if the recipe's estimate is off.")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        } else if recipeId != nil {
          Text("Weighing the ingredients…")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        } else {
          Text("Choose a recipe to see what's in it.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
  }

  private func planRow(index: Int, line: MealConsumptionPlanLine) -> some View {
    let quantityFormat = .number.precision(.fractionLength(0...2))
    let gramsBinding = Binding<Double>(
      get: { max(0, plan?.lines[index].plannedGrams ?? 0) },
      set: { newValue in
        // Fractional grams are fine; negatives and garbage are not.
        let clamped = newValue.isFinite ? max(0, newValue) : 0
        onLineEdited(index, clamped)
      }
    )

    return HStack(spacing: AppTheme.Space.sm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(line.displayName)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(1)
        if line.provenance == .userVerified {
          FLStatusPill(text: "Corrected by you", kind: .positive)
        }
      }

      Spacer()

      TextField("Grams", value: gramsBinding, format: quantityFormat)
        .font(AppTheme.Typography.dataSmall)
        .multilineTextAlignment(.trailing)
        .keyboardType(.decimalPad)
        .frame(width: 88)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Planned \(line.displayName) quantity")
        .accessibilityValue(
          "\(gramsBinding.wrappedValue, format: quantityFormat) grams, "
            + (line.provenance == .userVerified ? "corrected by you" : "suggested by the recipe")
        )
    }
    .padding(.vertical, AppTheme.Space.xxxs)
  }
}
