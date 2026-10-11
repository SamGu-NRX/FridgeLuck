import FLFeatureLogic
import SwiftUI

/// One labelled value row shared by the reference and portion cards, so both render the
/// same stored number the same way.
struct IngredientFactsValueRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer()
      Text(value)
        .font(AppTheme.Typography.dataSmall)
        .foregroundStyle(AppTheme.textPrimary)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The stored per-100 g reference. This card is deliberately distinct from the portion card
/// below it: warm surface, fixed values, a "per 100 g" qualifier on the energy line. It shows
/// exactly what the record stores and nothing scaled, estimated, or proportioned.
struct IngredientFactsReferenceCard: View {
  let reference: IngredientFactsReference

  var body: some View {
    FLCard(tone: .warm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("Reference", subtitle: "Stored nutrition, per 100 g", icon: "books.vertical")

        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs) {
          Text(IngredientFactsQuantity.kilocalories(reference.energyKilocalories))
            .font(AppTheme.Typography.dataLarge)
            .foregroundStyle(AppTheme.textPrimary)
          Text("per 100 g")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)

        Divider()
          .foregroundStyle(AppTheme.oat.opacity(0.20))

        VStack(spacing: AppTheme.Space.sm) {
          IngredientFactsValueRow(
            label: "Protein", value: IngredientFactsQuantity.grams(reference.proteinGrams))
          IngredientFactsValueRow(
            label: "Carbs", value: IngredientFactsQuantity.grams(reference.carbohydrateGrams))
          IngredientFactsValueRow(
            label: "Fat", value: IngredientFactsQuantity.grams(reference.fatGrams))
          IngredientFactsValueRow(
            label: "Fiber", value: IngredientFactsQuantity.grams(reference.fiberGrams))
          IngredientFactsValueRow(
            label: "Sugar", value: IngredientFactsQuantity.grams(reference.sugarGrams))
          IngredientFactsValueRow(
            label: "Sodium",
            value: IngredientFactsQuantity.milligrams(reference.sodiumMilligrams))
        }
      }
    }
  }
}

/// The reviewed portion: the user enters a finite positive weight in grams (or taps a
/// preset), and the stored reference scales to it. Input is always grams; the entered
/// weight is echoed in the user's preferred measurement unit. The reference card above
/// never changes, and nothing here writes to any record.
struct IngredientFactsPortionCard: View {
  let model: IngredientFactsModel

  @Environment(AppPreferencesStore.self) private var prefs
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var amountText = ""
  @FocusState private var amountIsFocused: Bool

  private static let presetGrams = [50, 100, 250]

  private var outcome: IngredientFactsPortionOutcome {
    model.portionOutcome(forText: amountText)
  }

  var body: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack(alignment: .top) {
          FLSectionHeader(
            "Your Portion",
            subtitle: "Scaled from the 100 g reference for the weight you enter",
            icon: "scalemass")
          Spacer()
          resetButton
        }

        amountField

        HStack(spacing: AppTheme.Space.xs) {
          ForEach(Self.presetGrams, id: \.self) { preset in
            presetChip(preset)
          }
        }

        Divider()
          .foregroundStyle(AppTheme.oat.opacity(0.20))

        outcomeArea
      }
    }
  }

  private var resetButton: some View {
    Button("Reset") {
      amountIsFocused = false
      withAnimation(reduceMotion ? nil : AppMotion.quick) { amountText = "" }
    }
    .font(AppTheme.Typography.label)
    .foregroundStyle(amountText.isEmpty ? AppTheme.textSecondary.opacity(0.5) : AppTheme.accent)
    .disabled(amountText.isEmpty)
    .accessibilityLabel("Reset portion weight")
    .accessibilityIdentifier("ingredient_facts_reset")
  }

  private var amountField: some View {
    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs) {
      TextField("Weight in grams", text: $amountText)
        .keyboardType(.decimalPad)
        .focused($amountIsFocused)
        .font(AppTheme.Typography.dataLarge)
        .foregroundColor(AppTheme.textPrimary)
        .accessibilityLabel("Portion weight in grams")
        .accessibilityIdentifier("ingredient_facts_portion_field")

      Text("g")
        .font(AppTheme.Typography.dataSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.xs)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
  }

  private func presetChip(_ preset: Int) -> some View {
    let selected: Bool
    if case .valid(let portion) = outcome {
      selected = portion.grams == Double(preset)
    } else {
      selected = false
    }

    return Button {
      amountIsFocused = false
      withAnimation(reduceMotion ? nil : AppMotion.quick) { amountText = String(preset) }
    } label: {
      Text("\(preset) g")
        .font(AppTheme.Typography.label)
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.chipVertical)
        .foregroundStyle(selected ? AppTheme.textPrimary : AppTheme.textSecondary)
        .background(
          (selected ? AppTheme.accent.opacity(0.22) : AppTheme.surface),
          in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(preset) grams")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .accessibilityIdentifier("ingredient_facts_preset_\(preset)")
  }

  @ViewBuilder
  private var outcomeArea: some View {
    switch outcome {
    case .empty:
      Label {
        Text(IngredientFactsInputError.empty.errorMessage)
      } icon: {
        Image(systemName: "text.cursor")
      }
      .font(AppTheme.Typography.bodySmall)
      .foregroundStyle(AppTheme.textSecondary)

    case .failed(let error):
      Label {
        Text(error.errorMessage)
      } icon: {
        Image(systemName: "exclamationmark.circle.fill")
      }
      .font(AppTheme.Typography.bodySmall)
      .foregroundStyle(AppTheme.accent)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(error.errorMessage)
      .accessibilityIdentifier("ingredient_facts_error")

    case .valid(let portion):
      portionDetails(portion)
    }
  }

  private func portionDetails(_ portion: IngredientFactsPortion) -> some View {
    VStack(spacing: AppTheme.Space.sm) {
      // Entered weight echoed in the user's preferred unit; the input basis stays grams.
      HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs) {
        Text(IngredientFactsQuantity.kilocalories(portion.energyKilocalories))
          .font(AppTheme.Typography.dataLarge)
          .foregroundStyle(AppTheme.textPrimary)
        Text("kcal")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text(prefs.formatWeight(grams: portion.grams))
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .accessibilityElement(children: .combine)

      IngredientFactsValueRow(
        label: "Protein", value: IngredientFactsQuantity.grams(portion.proteinGrams))
      IngredientFactsValueRow(
        label: "Carbs", value: IngredientFactsQuantity.grams(portion.carbohydrateGrams))
      IngredientFactsValueRow(label: "Fat", value: IngredientFactsQuantity.grams(portion.fatGrams))
      IngredientFactsValueRow(
        label: "Fiber", value: IngredientFactsQuantity.grams(portion.fiberGrams))
      IngredientFactsValueRow(
        label: "Sugar", value: IngredientFactsQuantity.grams(portion.sugarGrams))
      IngredientFactsValueRow(
        label: "Sodium", value: IngredientFactsQuantity.milligrams(portion.sodiumMilligrams))
    }
    .accessibilityIdentifier("ingredient_facts_portion_values")
  }
}
