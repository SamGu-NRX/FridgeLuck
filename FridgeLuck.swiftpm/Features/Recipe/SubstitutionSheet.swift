import SwiftUI

// MARK: - Substitution Sheet

/// Bottom sheet showing available substitutions for an ingredient.
/// Displays original → substitute comparison with reason badges and nutritional delta.
struct SubstitutionSheet: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let ingredient: Ingredient
  let quantityGrams: Double
  let displayQuantity: String
  var onSelect: (Substitution, Ingredient) -> Void

  @State private var substitutions: [Substitution] = []
  @State private var substituteIngredients: [Int64: Ingredient] = [:]
  @State private var originalMacros: RecipeMacros?
  @State private var substituteMacros: [Int64: RecipeMacros] = [:]
  @State private var appeared = false
  @State private var dietaryRestrictions: Set<String> = []

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
          originalCard
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)

          if substitutions.isEmpty {
            noSubstitutesView
          } else {
            substitutesList
          }
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.vertical, AppTheme.Space.md)
        .padding(.bottom, AppTheme.Space.xxl)
      }
      .navigationTitle("Swap Ingredient")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .font(AppTheme.Typography.label)
        }
      }
    }
    .flPageBackground()
    .task {
      await loadData()
      if !reduceMotion {
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(AppMotion.sectionReveal) {
          appeared = true
        }
      } else {
        appeared = true
      }
    }
  }

  // MARK: - Original Ingredient Card

  private var originalCard: some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(spacing: AppTheme.Space.sm) {
          Image(systemName: "arrow.triangle.swap")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
            .frame(width: 28, height: 28)
            .background(AppTheme.accentMuted, in: Circle())

          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text("Current ingredient")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
            Text(ingredient.displayName)
              .font(AppTheme.Typography.displayCaption)
              .foregroundStyle(AppTheme.textPrimary)
          }

          Spacer()

          Text(displayQuantity)
            .font(AppTheme.Typography.dataSmall)
            .foregroundStyle(AppTheme.accent)
        }

        if let macros = originalMacros {
          compactMacroRow(macros: macros, highlight: false)
        }
      }
    }
  }

  // MARK: - No Substitutes

  private var noSubstitutesView: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: "leaf.circle")
          .font(.system(size: 32))
          .foregroundStyle(AppTheme.textSecondary)
        Text("No substitutes available")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
        Text("This ingredient doesn't have any swaps in our catalog yet.")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.md)
    }
  }

  // MARK: - Substitutes List

  private var substitutesList: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      FLSectionHeader(
        "Available Swaps",
        subtitle: "\(substitutions.count) option\(substitutions.count == 1 ? "" : "s")",
        icon: "arrow.triangle.swap"
      )
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 8)

      ForEach(Array(substitutions.enumerated()), id: \.element.id) { index, sub in
        if let subIngredient = substituteIngredients[sub.substituteId] {
          substituteCard(sub, ingredient: subIngredient, index: index)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(
              reduceMotion ? nil : AppMotion.sectionReveal.delay(Double(index) * 0.05),
              value: appeared
            )
        }
      }
    }
  }

  // MARK: - Substitute Card

  private func substituteCard(
    _ substitution: Substitution, ingredient subIngredient: Ingredient, index: Int
  ) -> some View {
    Button {
      onSelect(substitution, subIngredient)
      dismiss()
    } label: {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(alignment: .top, spacing: AppTheme.Space.sm) {
          Image(systemName: "arrow.right.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(AppTheme.sage)

          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text(subIngredient.displayName)
              .font(AppTheme.Typography.displayCaption)
              .foregroundStyle(AppTheme.textPrimary)

            let adjustedGrams = quantityGrams * substitution.ratio
            Text(
              formatAdjustedQuantity(
                grams: adjustedGrams,
                substituteName: subIngredient.displayName
              )
            )
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
          }

          Spacer()

          if substitution.ratio != 1.0 {
            Text(formatRatio(substitution.ratio))
              .font(AppTheme.Typography.labelSmall)
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxxs)
              .background(AppTheme.oat.opacity(0.3), in: Capsule())
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        FlowLayout(spacing: AppTheme.Space.xxs) {
          ForEach(
            Array(substitution.reasons).sorted(by: { $0.rawValue < $1.rawValue }),
            id: \.rawValue
          ) { reason in
            reasonBadge(reason)
          }
        }

        if let subMacros = substituteMacros[substitution.substituteId],
          let origMacros = originalMacros
        {
          nutritionComparison(original: origMacros, substitute: subMacros)
        }

        if let note = substitution.note {
          HStack(alignment: .top, spacing: AppTheme.Space.xs) {
            Image(systemName: "lightbulb.min")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(AppTheme.oat)
            Text(note)
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, AppTheme.Space.xxs)
        }
      }
      .padding(AppTheme.Space.md)
      .background(
        AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
      )
      .shadow(color: AppTheme.Shadow.color, radius: 6, x: 0, y: 2)
    }
    .buttonStyle(SubstitutionCardButtonStyle())
  }

  // MARK: - Reason Badge

  private func reasonBadge(_ reason: SubstitutionReason) -> some View {
    let isDietaryMatch =
      dietaryRestrictions.isEmpty
      ? false
      : !SubstitutionReason.reasons(forRestrictions: dietaryRestrictions).isDisjoint(with: [reason])

    return HStack(spacing: AppTheme.Space.xxs) {
      Image(systemName: reason.icon)
        .font(.system(size: 10, weight: .semibold))
      Text(reason.rawValue)
        .font(AppTheme.Typography.labelSmall)
    }
    .padding(.horizontal, AppTheme.Space.xs)
    .padding(.vertical, AppTheme.Space.xxxs + 2)
    .foregroundStyle(isDietaryMatch ? AppTheme.sage : AppTheme.textSecondary)
    .background(
      isDietaryMatch ? AppTheme.sage.opacity(0.12) : AppTheme.surfaceMuted,
      in: Capsule()
    )
  }

  // MARK: - Nutrition Comparison

  private func nutritionComparison(original: RecipeMacros, substitute: RecipeMacros) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      macroDelta(
        "Cal",
        original: caloriesFromDisplayedMacros(original),
        new: caloriesFromDisplayedMacros(substitute),
        unit: ""
      )
      macroDelta(
        "P", original: original.proteinPerServing, new: substitute.proteinPerServing, unit: "g")
      macroDelta(
        "C", original: original.carbsPerServing, new: substitute.carbsPerServing, unit: "g")
      macroDelta("F", original: original.fatPerServing, new: substitute.fatPerServing, unit: "g")
      Spacer()
    }
    .padding(AppTheme.Space.xs)
    .background(
      AppTheme.surfaceMuted.opacity(0.5),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
    )
  }

  private func macroDelta(_ label: String, original: Double, new: Double, unit: String) -> some View
  {
    let delta = new - original
    let sign = delta >= 0 ? "+" : ""
    let color: Color =
      abs(delta) < 1
      ? AppTheme.textSecondary
      : (label == "Cal" || label == "F")
        ? (delta < 0 ? AppTheme.sage : AppTheme.accent)
        : (label == "P") ? (delta > 0 ? AppTheme.sage : AppTheme.accent) : AppTheme.textSecondary

    return VStack(spacing: AppTheme.Space.xxxs) {
      Text("\(sign)\(Int(delta.rounded()))\(unit)")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(color)
      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  // MARK: - Compact Macro Row

  private func compactMacroRow(macros: RecipeMacros, highlight: Bool) -> some View {
    HStack(spacing: AppTheme.Space.md) {
      compactMacro("Cal", value: Int(caloriesFromDisplayedMacros(macros).rounded()), unit: "")
      compactMacro("P", value: Int(macros.proteinPerServing.rounded()), unit: "g")
      compactMacro("C", value: Int(macros.carbsPerServing.rounded()), unit: "g")
      compactMacro("F", value: Int(macros.fatPerServing.rounded()), unit: "g")
      Spacer()
    }
    .padding(AppTheme.Space.xs)
    .background(
      AppTheme.surfaceMuted.opacity(0.4),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
    )
  }

  private func compactMacro(_ label: String, value: Int, unit: String) -> some View {
    HStack(spacing: AppTheme.Space.xxxs) {
      Text("\(value)\(unit)")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textPrimary)
      Text(label)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  // MARK: - Helpers

  private func formatAdjustedQuantity(grams: Double, substituteName: String) -> String {
    let roundedGrams = Int(grams.rounded())
    return "\(roundedGrams)g \(substituteName.lowercased())"
  }

  private func formatRatio(_ ratio: Double) -> String {
    if ratio == 1.0 { return "1:1" }
    let nice: String = {
      switch ratio {
      case 0.5: return "½×"
      case 0.75: return "¾×"
      case 1.5: return "1½×"
      default: return String(format: "%.1f×", ratio)
      }
    }()
    return nice
  }

  private func caloriesFromDisplayedMacros(_ macros: RecipeMacros) -> Double {
    (macros.proteinPerServing * 4) + (macros.carbsPerServing * 4) + (macros.fatPerServing * 9)
  }

  // MARK: - Data Loading

  private func loadData() async {
    if let profile = try? deps.userDataRepository.fetchHealthProfile() {
      dietaryRestrictions = profile.normalizedDietaryRestrictionIDs
    }

    let subs = deps.substitutionService.substitutions(
      for: ingredient.id ?? -1,
      dietaryRestrictions: dietaryRestrictions
    )
    substitutions = subs

    for sub in subs {
      if let subIngredient = try? deps.substitutionService.ingredient(id: sub.substituteId) {
        substituteIngredients[sub.substituteId] = subIngredient
        let adjustedGrams = quantityGrams * sub.ratio
        substituteMacros[sub.substituteId] = try? deps.nutritionService.ingredientMacros(
          ingredientId: sub.substituteId, grams: adjustedGrams
        )
      }
    }

    originalMacros = try? deps.nutritionService.ingredientMacros(
      ingredientId: ingredient.id ?? -1, grams: quantityGrams
    )
  }
}

// MARK: - Card Button Style

private struct SubstitutionCardButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
      .animation(reduceMotion ? nil : AppMotion.buttonSpring, value: configuration.isPressed)
  }
}
