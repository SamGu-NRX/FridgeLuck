import SwiftUI

/// Correct a logged meal: per-ingredient quantities, servings, portion, and the cooked
/// day. The revised totals and per-line Kitchen consequences are visible before the
/// explicit "Save Correction" button — nothing is written until it is tapped.
struct MealCorrectionSheet: View {
  @EnvironmentObject var deps: AppDependencies
  @Environment(\.dismiss) private var dismiss

  let entry: CookingJournalEntry
  let acceptedState: AcceptedMealState
  var onSaved: () -> Void = {}

  @State private var plan: MealConsumptionPlan
  @State private var cookedDay: Date
  @State private var saving = false
  @State private var errorMessage: String?
  @State private var preview: [MealPlanLinePreview] = []

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    entry: CookingJournalEntry, acceptedState: AcceptedMealState,
    onSaved: @escaping () -> Void = {}
  ) {
    self.entry = entry
    self.acceptedState = acceptedState
    self.onSaved = onSaved
    _plan = State(initialValue: acceptedState.plan)
    _cookedDay = State(initialValue: entry.cookedAt)
  }

  private var revisedTotals: MealNutritionPer100g { plan.totalMacros }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
          MealPlanEditorSection(plan: plan, recipeId: entry.recipe.id) { index, grams in
            applyLineEdit(index: index, grams: grams)
          }

          servingsPortionSection

          cookedDaySection

          consequencesSection

          if let errorMessage {
            FLStatusPill(text: errorMessage, kind: .warning)
          }

          FLPrimaryButton(
            saving ? "Saving…" : "Save Correction",
            systemImage: "checkmark.circle",
            action: save
          )
          .disabled(saving)
          .padding(.bottom, AppTheme.Space.bottomClearance)
        }
        .padding([.horizontal, .top], AppTheme.Space.page)
      }
      .navigationTitle("Correct Entry")
      .navigationBarTitleDisplayMode(.inline)
      .flPageBackground()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .onAppear { refreshPreview() }
    }
  }

  // MARK: - Servings, Portion, Day

  private var servingsPortionSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("HOW MUCH YOU ATE")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      FLCard {
        VStack(spacing: AppTheme.Space.md) {
          Stepper(
            "Servings: \(plan.servingsConsumed)",
            value: Binding(
              get: { plan.servingsConsumed },
              set: { newValue in rescale(servings: newValue, portion: plan.portionMultiplier) }
            ), in: 1...10
          )
          .accessibilityLabel("Servings eaten")
          .accessibilityValue("\(plan.servingsConsumed) servings")

          Stepper(
            "Portion: \(Int((plan.portionMultiplier * 100).rounded()))%",
            value: Binding(
              get: { plan.portionMultiplier },
              set: { newValue in rescale(servings: plan.servingsConsumed, portion: newValue) }
            ), in: 0.25...3, step: 0.25
          )
          .accessibilityLabel("Portion size")
          .accessibilityValue(
            "\(Int((plan.portionMultiplier * 100).rounded())) percent of a serving")
        }
      }
    }
  }

  private var cookedDaySection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("COOKED ON")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      FLCard {
        DatePicker(
          "Cooked on",
          selection: Binding(
            get: { cookedDay },
            set: { newValue in
              cookedDay = newValue
              plan.acceptedStreakDay = PersonalizationService.formatDate(newValue)
            }
          ),
          displayedComponents: .date
        )
        .accessibilityLabel("Day the meal was cooked")
        .accessibilityValue(Text(cookedDay, format: .dateTime.month().day().year()))
      }
    }
  }

  // MARK: - Consequences

  private var consequencesSection: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("REVISED MEAL")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      FLCard {
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text("\(Int(revisedTotals.calories.rounded()))")
              .font(AppTheme.Typography.displayMedium)
              .foregroundStyle(AppTheme.accent)
            Text("calories after correction")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          }

          Divider()

          // Per-line Kitchen consequences, visible before anything is saved.
          VStack(spacing: AppTheme.Space.xs) {
            ForEach(preview, id: \.lineKey) { line in
              HStack {
                Text(line.ingredientName)
                  .font(AppTheme.Typography.bodyMedium)
                  .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(kitchenConsequence(line))
                  .font(AppTheme.Typography.bodySmall)
                  .foregroundStyle(
                    line.shortfallGrams > 0.001 ? AppTheme.warning : AppTheme.textSecondary)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel("Kitchen effect for \(line.ingredientName)")
              .accessibilityValue(kitchenConsequence(line))
            }
            if preview.isEmpty {
              Text("Kitchen totals stay as they are for this meal.")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
        }
      }
    }
  }

  /// Human phrasing for what saving would take out of the Kitchen for this line.
  private func kitchenConsequence(_ line: MealPlanLinePreview) -> String {
    if line.shortfallGrams > 0.001 {
      return
        "Takes \(Int(line.plannedGrams.rounded())) g — \(Int(line.shortfallGrams.rounded())) g short in the Kitchen"
    }
    return "Takes \(Int(line.deductedGrams.rounded())) g from the Kitchen"
  }

  // MARK: - Actions

  private func applyLineEdit(index: Int, grams: Double) {
    guard plan.lines.indices.contains(index) else { return }
    let clamped = grams.isFinite ? max(0, grams) : 0
    plan.lines[index].plannedGrams = clamped
    // Editing a line is the user's own correction of the recipe's estimate.
    plan.lines[index].provenance = .userVerified
    withAnimation(reduceMotion ? nil : AppMotion.gentle) { refreshPreview() }
  }

  /// Servings and portion changes rescale the recipe's suggested quantities and keep
  /// user-verified lines at their absolute grams — the same rule as logging.
  private func rescale(servings: Int, portion: Double) {
    plan = plan.rescaled(servingsConsumed: servings, portionMultiplier: portion)
    plan.acceptedStreakDay = PersonalizationService.formatDate(cookedDay)
    refreshPreview()
  }

  private func refreshPreview() {
    preview = (try? deps.inventoryRepository.previewPlanConsumption(plan: plan)) ?? []
  }

  private func save() {
    saving = true
    errorMessage = nil
    do {
      // A same-day picker value is not a date edit: the service keeps the original
      // time of day, and no revision-worthy change is implied.
      let dayChanged =
        PersonalizationService.formatDate(cookedDay)
        != PersonalizationService.formatDate(entry.cookedAt)
      let outcome = try deps.mealCorrectionService.correctMeal(
        historyId: entry.id, correctedPlan: plan,
        editedCookedAt: dayChanged ? cookedDay : nil)
      let revision = outcome.acceptedRevision
      let recordedAt = outcome.acceptedCookedAt ?? entry.cookedAt
      Task { @MainActor in
        await deps.mealLogSyncCoordinator.syncCorrectedMeal(
          historyId: entry.id, mealTitle: entry.recipe.title, correctedPlan: plan,
          acceptedRevision: revision, recordedAt: recordedAt)
        onSaved()
        dismiss()
      }
    } catch {
      errorMessage = error.localizedDescription
      saving = false
    }
  }
}
