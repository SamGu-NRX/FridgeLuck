import SwiftUI
import FLFeatureLogic

/// Read-only amount review for the recipe's current plan: every ingredient amount and
/// calorie value recomputed for a chosen serving count, including the selected substitutes.
///
/// This sheet changes nothing. It reads fresh from the same database the plan uses, and the
/// selected serving count never flows back into the cooking plan, inventory, or meal log —
/// the UI says so, permanently, at the top.
struct RecipeQuantityReviewView: View {
  let recipeID: Int64
  let activeSubstitutions: [Int64: (substitution: Substitution, ingredient: Ingredient)]

  @EnvironmentObject var deps: AppDependencies
  @Environment(AppPreferencesStore.self) private var prefs
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss

  private enum LoadState {
    case loading
    case ready(RecipeQuantityReviewSnapshot)
    case failed(RecipeQuantityReviewFailure)
  }

  @State private var loadState: LoadState = .loading
  @State private var selectedServings: Double?

  var body: some View {
    NavigationStack {
      Group {
        switch loadState {
        case .loading:
          VStack(spacing: AppTheme.Space.sm) {
            ProgressView()
            Text("Reading your current plan…")
              .font(AppTheme.Typography.bodySmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
          failureView(failure)
        case .ready(let snapshot):
          readyView(snapshot)
        }
      }
      .background(AppTheme.bg)
      .navigationTitle("Amount review")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
    .task(id: recipeID) {
      await load()
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: - Loading

  private func load() async {
    // Clear committed facts first: a stale or failed load can never leave the previous
    // recipe's values on screen.
    loadState = .loading
    let reader = AppRecipeQuantityReviewReader(
      recipeRepository: deps.recipeRepository,
      nutritionService: deps.nutritionService,
      activeSubstitutions: activeSubstitutions)
    let session = RecipeQuantityReviewSession(read: reader)
    do {
      let snapshot = try await session.load(recipeID: recipeID)
      guard !Task.isCancelled else { return }
      loadState = .ready(snapshot)
      selectedServings = RecipeQuantityReviewCalculator.defaultSelectedServings(
        recipeServings: snapshot.recipeServings)
    } catch let failure as RecipeQuantityReviewFailure {
      guard !Task.isCancelled else { return }
      loadState = .failed(failure)
    } catch is CancellationError {
      // The sheet left the screen or the identity changed; no state is committed.
    } catch {
      guard !Task.isCancelled else { return }
      loadState = .failed(.readFailed(String(describing: error)))
    }
  }

  // MARK: - Ready

  private func readyView(_ snapshot: RecipeQuantityReviewSnapshot) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        readOnlyBanner
        referenceCard(snapshot)
        servingsCard(snapshot)
        rowsCard(snapshot)
        totalsCard(snapshot)
      }
      .padding(AppTheme.Space.page)
      .padding(.bottom, AppTheme.Space.page)
    }
  }

  private var readOnlyBanner: some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: "eye")
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.accent)
      Text(
        "Read-only review. Servings here don't change your cooking plan, inventory, or meal log."
      )
      .font(AppTheme.Typography.bodySmall)
      .foregroundStyle(AppTheme.textSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(AppTheme.Space.sm)
    .background(AppTheme.accentLight)
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    .accessibilityElement(children: .combine)
  }

  private func referenceCard(_ snapshot: RecipeQuantityReviewSnapshot) -> some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        FLSectionHeader("Reference", subtitle: "Recipe as planned", icon: "bookmark")
        if let reference = snapshot.referenceCaloriesPerServing {
          Text(
            "\(snapshot.recipeServings) \(snapshot.recipeServings == 1 ? "serving" : "servings") · ~\(Int(reference.rounded())) kcal per serving"
          )
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)
        } else {
          Text("Per-serving reference unavailable")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Text("Your health recommendation stays as shown in the preview; this review only recalculates amounts.")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
  }

  private func servingsCard(_ snapshot: RecipeQuantityReviewSnapshot) -> some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("Reviewed servings", icon: "person.2")
        HStack {
          servingStepButton(
            systemImage: "minus",
            label: "Fewer servings",
            disabled: canStepDown == false
          ) {
            stepServings(by: -1)
          }
          Spacer()
          Text(servingLabel)
            .font(AppTheme.Typography.displayMedium)
            .foregroundStyle(AppTheme.textPrimary)
            .monospacedDigit()
            .accessibilityLabel(accessibilityServingsLabel(snapshot))
          Spacer()
          servingStepButton(
            systemImage: "plus",
            label: "More servings",
            disabled: canStepUp == false
          ) {
            stepServings(by: 1)
          }
        }
        Text("Amounts below are per the selected serving count. The recipe as planned is \(snapshot.recipeServings) \(snapshot.recipeServings == 1 ? "serving" : "servings").")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
  }

  private func servingStepButton(
    systemImage: String, label: String, disabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(disabled ? AppTheme.textSecondary.opacity(0.4) : AppTheme.textPrimary)
        .frame(width: 44, height: 44)
        .background(AppTheme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }
    .buttonStyle(FLPressableButtonStyle())
    .disabled(disabled)
    .accessibilityLabel(label)
  }

  private var servingOptions: [Double] { RecipeQuantityReviewCalculator.servingOptions }

  private var selectedIndex: Int? {
    guard let selectedServings else { return nil }
    return servingOptions.firstIndex(of: selectedServings)
  }

  private var canStepDown: Bool {
    guard let index = selectedIndex else { return false }
    return index > 0
  }

  private var canStepUp: Bool {
    guard let index = selectedIndex else { return false }
    return index < servingOptions.count - 1
  }

  private func stepServings(by step: Int) {
    guard let index = selectedIndex else { return }
    let next = servingOptions[index + step]
    guard next.isFinite, next > 0 else { return }
    if reduceMotion {
      selectedServings = next
    } else {
      withAnimation(.easeOut(duration: 0.2)) {
        selectedServings = next
      }
    }
  }

  private var servingLabel: String {
    guard let selectedServings else { return "—" }
    let rounded = (selectedServings * 10).rounded() / 10
    if rounded == rounded.rounded() {
      let whole = Int(rounded)
      return "\(whole) \(whole == 1 ? "serving" : "servings")"
    }
    return "\(rounded) servings"
  }

  private func accessibilityServingsLabel(_ snapshot: RecipeQuantityReviewSnapshot) -> String {
    guard let selectedServings else { return "Servings" }
    return "Reviewed servings, \(servingLabel). The recipe as planned is \(snapshot.recipeServings) \(snapshot.recipeServings == 1 ? "serving" : "servings")."
  }

  // MARK: - Rows

  private func rowsCard(_ snapshot: RecipeQuantityReviewSnapshot) -> some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        FLSectionHeader("Amounts", subtitle: "At the selected servings", icon: "scalemass")
        if snapshot.rows.isEmpty {
          Text("No ingredient amounts to review.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        } else {
          VStack(spacing: AppTheme.Space.xxs) {
            ForEach(snapshot.rows, id: \.ingredientID) { row in
              amountRow(row, snapshot: snapshot)
            }
          }
          Text("Optional items are listed separately below and are never added to the required total.")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.top, AppTheme.Space.xxs)
        }
      }
    }
  }

  @ViewBuilder
  private func amountRow(
    _ row: RecipeQuantityReviewSnapshot.Row, snapshot: RecipeQuantityReviewSnapshot
  ) -> some View {
    let factor = currentFactor(snapshot: snapshot)
    let amounts = RecipeQuantityReviewCalculator.amounts(row: row, servingFactor: factor)
    VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          HStack(spacing: AppTheme.Space.xxs) {
            Text(row.originalName)
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textPrimary)
            if let replacement = row.replacementName {
              Text("replaced by \(replacement)")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.sage)
            }
          }
          HStack(spacing: AppTheme.Space.xxs) {
            if row.isRequired {
              FLStatusPill(text: "Required", kind: .neutral)
            } else {
              FLStatusPill(text: "Optional", kind: .neutral)
            }
            if let ratio = row.substituteRatio {
              Text("×\(String(format: "%.2g", ratio)) ratio")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: AppTheme.Space.xxxs) {
          Text(prefs.formatWeight(grams: amounts.originalGrams))
            .font(AppTheme.Typography.dataMedium)
            .foregroundStyle(AppTheme.textPrimary)
            .monospacedDigit()
          if let replacementGrams = amounts.replacementGrams {
            Text(prefs.formatWeight(grams: replacementGrams))
              .font(AppTheme.Typography.dataMedium)
              .foregroundStyle(AppTheme.sage)
              .monospacedDigit()
          }
        }
      }
      calorieLine(
        original: amounts.originalCalories,
        replacement: amounts.replacementCalories,
        isSubstituted: row.replacementName != nil)
      Divider()
        .overlay(AppTheme.surfaceMuted)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityRowLabel(row, amounts: amounts))
  }

  @ViewBuilder
  private func calorieLine(
    original: Double?, replacement: Double?, isSubstituted: Bool
  ) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      if let original {
        Text("~\(Int(original.rounded())) kcal")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
          .monospacedDigit()
      } else {
        Text("Calories unavailable")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
      if isSubstituted {
        if let replacement {
          Image(systemName: "arrow.right")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.sage)
          Text("~\(Int(replacement.rounded())) kcal")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.sage)
            .monospacedDigit()
        } else {
          Text("Substitute calories unavailable")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      Spacer()
    }
  }

  private func totalsCard(_ snapshot: RecipeQuantityReviewSnapshot) -> some View {
    let factor = currentFactor(snapshot: snapshot)
    let required = RecipeQuantityReviewCalculator.requiredTotalCalories(
      rows: snapshot.rows, servingFactor: factor)
    let optional = RecipeQuantityReviewCalculator.optionalTotalCalories(
      rows: snapshot.rows, servingFactor: factor)
    return FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
        FLSectionHeader("Totals", subtitle: "At the selected servings", icon: "sum")
        totalLine(
          label: "Required total",
          calories: required,
          color: AppTheme.textPrimary)
        totalLine(
          label: "Optional total (listed separately)",
          calories: optional,
          color: AppTheme.textSecondary)
        if required == nil {
          Text("A total needs every item's nutrition; something couldn't be read, so no total is shown rather than a wrong one.")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
  }

  @ViewBuilder
  private func totalLine(label: String, calories: Double?, color: Color) -> some View {
    HStack {
      Text(label)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer()
      if let calories {
        Text("~\(Int(calories.rounded())) kcal")
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(color)
          .monospacedDigit()
      } else {
        Text("Unavailable")
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func currentFactor(snapshot: RecipeQuantityReviewSnapshot) -> Double {
    guard let selectedServings else {
      // The amounts as planned. Reaching the UI without a selection cannot happen (the
      // default is set before .ready commits), so this stays the identity factor instead
      // of an invented one.
      return 1
    }
    guard let factor = try? RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: selectedServings, recipeServings: snapshot.recipeServings)
    else { return 1 }
    return factor
  }

  private func accessibilityRowLabel(
    _ row: RecipeQuantityReviewSnapshot.Row, amounts: RecipeQuantityReviewCalculator.RowAmounts
  ) -> String {
    var parts: [String] = []
    parts.append(row.originalName)
    parts.append(row.isRequired ? "Required" : "Optional")
    parts.append("original \(prefs.formatWeight(grams: amounts.originalGrams))")
    if let replacement = amounts.replacementGrams, let name = row.replacementName {
      parts.append("substituted with \(name) \(prefs.formatWeight(grams: replacement))")
    }
    if let calories = amounts.replacementCalories ?? amounts.originalCalories {
      parts.append("~\(Int(calories.rounded())) kilocalories")
    }
    return parts.joined(separator: ", ")
  }

  // MARK: - Failure

  private func failureView(_ failure: RecipeQuantityReviewFailure) -> some View {
    VStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 28))
        .foregroundStyle(AppTheme.warning)
      Text(failureTitle(failure))
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)
        .multilineTextAlignment(.center)
      Text(failureDetail(failure))
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
      FLPrimaryButton(title: "Try again", systemImage: "arrow.clockwise") {
        Task { await load() }
      }
      .padding(.top, AppTheme.Space.xxs)
    }
    .padding(AppTheme.Space.page)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failureTitle(_ failure: RecipeQuantityReviewFailure) -> String {
    switch failure {
    case .missingRecipeID, .noIngredientRows:
      return "Nothing to review yet"
    case .recipeNotFound:
      return "Recipe not found"
    case .inconsistentRows:
      return "Amounts can't be reviewed"
    case .invalidRecipeServings:
      return "Serving count is unusable"
    case .readFailed:
      return "Couldn't read your plan"
    }
  }

  private func failureDetail(_ failure: RecipeQuantityReviewFailure) -> String {
    switch failure {
    case .missingRecipeID:
      return "This ingredient isn't tied to a saved recipe, so there are no amounts to review."
    case .recipeNotFound:
      return "The recipe this item belongs to could not be found in your plan."
    case .noIngredientRows:
      return "The recipe has no ingredient amounts saved yet."
    case .inconsistentRows:
      return "The saved ingredient rows disagree with each other, so no amounts can be shown safely."
    case .invalidRecipeServings(let servings):
      return "The recipe's saved serving count is \(servings), which can't be used to scale amounts."
    case .readFailed:
      return "Reading the saved amounts failed. Your data wasn't changed — try again."
    }
  }
}
