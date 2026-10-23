import Foundation

/// Everything the plan sheet shows, as plain values (SPEC.md §3.2). `PlanSheetView` renders
/// this and nothing else, so the words and numbers each state puts on screen are tested here
/// without a view hierarchy.
///
/// Every dinner and shopping row comes from the view model's plan, which the allocator built
/// from the snapshot's admitted candidates; this type never adds a recipe or an ingredient.
public struct PlanSheetContent: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case loading
    /// The snapshot read failed; `message` says so and the sheet offers a retry.
    case failed
    /// No inventory lots exist: "I don't know your kitchen yet."
    case emptyKitchen
    /// The household screen admitted no recipe, so there is nothing to plan or shop for.
    case noRecipes
    /// Recipes exist but none is coverable; `dinners` are a shop-first plan, `shopping` first.
    case nothingFits
    case planned
  }

  public enum SaveControl: Equatable, Sendable {
    case save
    case saving
    case saved
    /// The last save failed; the control reads as a retry.
    case retry
  }

  /// One ingredient row inside a dinner: a name and what the row says about it.
  public struct LineRow: Equatable, Sendable {
    public let name: String
    public let detail: String

    public init(name: String, detail: String) {
      self.name = name
      self.detail = detail
    }
  }

  public struct DinnerCard: Equatable, Sendable, Identifiable {
    /// Changes when the recipe at this position changes, so a swapped dinner is a new card.
    public let id: String
    /// Index into the plan's dinners, for the view model's per-dinner calls.
    public let index: Int
    public let positionLabel: String
    public let title: String
    public let timeText: String?
    public let servings: Int
    public let canChangeServings: Bool
    public let canSwap: Bool
    /// Built from line states only, never a percentage (PR #86 §3.2).
    public let fitText: String
    public let fromKitchen: [LineRow]
    public let toBuy: [LineRow]
    public let toCheck: [LineRow]
    /// Reviewed ingredient substitutions the allocator applied.
    public let substitutions: [LineRow]
    /// The card header as VoiceOver reads it: one element with the dinner's summary.
    public let accessibilitySummary: String
  }

  public struct ShoppingRow: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let name: String
    public let grams: Double
    public let amountText: String
    /// Struck through on screen: every gram came from a line assumed on hand.
    public let usuallyOnHand: Bool
    public let accessibilityLabel: String
  }

  public let kind: Kind
  public let title: String
  public let subtitle: String
  public let headline: String?
  public let message: String?
  /// Lines that qualify the plan: fewer dinners than asked for, a swap with nothing to swap
  /// in, a saved dinner replaced on open.
  public let notes: [String]
  public let dinners: [DinnerCard]
  public let shopping: [ShoppingRow]
  /// Said under the shopping heading when a plan needs nothing bought.
  public let shoppingEmptyText: String?
  public let save: SaveControl?
  public let saveFailureText: String?
  /// Dinner count and "Plan different dinners" apply only once recipes exist to plan from.
  public let showsPlanControls: Bool

  @MainActor
  public init(_ model: PlanSheetViewModel) {
    self.init(
      state: model.state, errorMessage: model.errorMessage, plan: model.plan,
      shoppingFirstPlan: model.shoppingFirstPlan, dinnerCount: model.dinnerCount,
      sparseKitchen: model.sparseKitchen, notice: model.notice,
      saveStatus: model.supportsSaving ? model.saveStatus : nil)
  }

  public init(
    state: PlanSheetViewModel.State, errorMessage: String?, plan: LeChefPlan?,
    shoppingFirstPlan: LeChefPlan?, dinnerCount: Int, sparseKitchen: Bool, notice: String?,
    saveStatus: PlanSheetViewModel.SaveStatus?
  ) {
    title = dinnerCount == 1 ? "Next dinner" : "Next \(dinnerCount) dinners"
    subtitle = "From what's in your Kitchen now."
    var notes: [String] = []
    if let notice { notes.append(notice) }

    switch state {
    case .idle where errorMessage != nil:
      kind = .failed
      headline = "Couldn't read your kitchen"
      message = errorMessage
      dinners = []
      shopping = []
      shoppingEmptyText = nil
      showsPlanControls = false
    case .idle, .loading:
      kind = .loading
      headline = nil
      message = nil
      dinners = []
      shopping = []
      shoppingEmptyText = nil
      showsPlanControls = false
    case .empty:
      kind = .emptyKitchen
      headline = "I don't know your kitchen yet"
      message = "Add what you have, or scan your shelf, and I'll plan dinners from it."
      dinners = []
      shopping = []
      shoppingEmptyText = nil
      showsPlanControls = false
    case .nothingFeasible:
      if let shoppingFirstPlan {
        kind = .nothingFits
        headline = "Nothing fits what you have yet"
        message =
          "Every dinner is missing more than two ingredients. This shop would cover the "
          + (shoppingFirstPlan.dinners.count == 1 ? "dinner below." : "dinners below.")
        dinners = Self.cards(shoppingFirstPlan, shopFirst: true)
        shopping = Self.rows(shoppingFirstPlan.shoppingList)
        showsPlanControls = true
      } else {
        kind = .noRecipes
        headline = "No recipes to plan from"
        message = "No recipe here fits your household's allergies and diet right now."
        dinners = []
        shopping = []
        showsPlanControls = false
      }
      shoppingEmptyText = nil
    case .ready:
      kind = .planned
      headline = nil
      message = nil
      // The view model sets `plan` whenever it reports `.ready`.
      let planned = plan?.dinners.count ?? 0
      if sparseKitchen {
        notes.insert(
          "Your kitchen covers \(planned) of the \(dinnerCount) dinners you asked for.", at: 0)
      }
      dinners = plan.map { Self.cards($0, shopFirst: false) } ?? []
      let rows = Self.rows(plan?.shoppingList ?? [])
      shopping = rows
      // Unknown and estimated amounts make no buy line, so they also make no coverage claim.
      let unconfirmed = (plan?.dinners ?? []).flatMap(\.lines).contains {
        $0.isRequired && ($0.lineState == .quantityUnknown || $0.lineState == .needsReconfirming)
      }
      shoppingEmptyText =
        !rows.isEmpty
        ? nil
        : unconfirmed
          ? "Nothing to buy for what's recorded. Check the amounts listed under Check."
          : "Nothing to buy. Your kitchen covers these dinners."
      showsPlanControls = true
    }
    self.notes = notes

    if state == .ready, let saveStatus {
      switch saveStatus {
      case .unsaved: save = .save
      case .saving: save = .saving
      case .saved: save = .saved
      case .failed: save = .retry
      }
      saveFailureText = saveStatus == .failed ? "Couldn't save the plan. Try again." : nil
    } else {
      save = nil
      saveFailureText = nil
    }
  }

  // MARK: - Dinners

  private static func cards(_ plan: LeChefPlan, shopFirst: Bool) -> [DinnerCard] {
    plan.dinners.enumerated().map { index, dinner in
      card(dinner, index: index, in: plan, shopFirst: shopFirst)
    }
  }

  private static func card(
    _ dinner: PlannedDinner, index: Int, in plan: LeChefPlan, shopFirst: Bool
  ) -> DinnerCard {
    let positionLabel = "Dinner \(dinner.position)"
    let title = dinner.title
    let timeText = dinner.timeMinutes.map { "\($0) min" }
    let servingsText = dinner.servings == 1 ? "1 serving" : "\(dinner.servings) servings"
    let id = "\(dinner.dinnerID)-\(dinner.recipeDatabaseID)"

    if let sourceID = dinner.leftoverOfDinnerID {
      let source = plan.dinners.first { $0.dinnerID == sourceID }
      let fit = source.map { "Leftovers from dinner \($0.position)" } ?? "Leftovers"
      return DinnerCard(
        id: id, index: index, positionLabel: positionLabel, title: title, timeText: nil,
        servings: dinner.servings, canChangeServings: false, canSwap: false, fitText: fit,
        fromKitchen: [], toBuy: [], toCheck: [], substitutions: [],
        accessibilitySummary: "\(positionLabel). \(title). \(fit). \(servingsText).")
    }

    var fromKitchen: [LineRow] = []
    var toBuy: [LineRow] = []
    var toCheck: [LineRow] = []
    var substitutions: [LineRow] = []
    for line in dinner.lines {
      let name = PlanSheetText.ingredientName(line.name)
      if let swap = line.swap {
        let substitute = swap.substituteName.map(PlanSheetText.ingredientName) ?? "A reviewed swap"
        var detail = swap.substituteGrams.map { PlanQuantity(value: $0).displayText } ?? ""
        if let note = swap.note, !note.isEmpty {
          detail = detail.isEmpty ? note : "\(detail) · \(note)"
        }
        substitutions.append(LineRow(name: "\(substitute) for \(name)", detail: detail))
        if let originalGrams = swap.originalGrams, originalGrams > 0 {
          fromKitchen.append(
            LineRow(name: name, detail: PlanQuantity(value: originalGrams).displayText))
        }
        if line.lineState == .needsReconfirming {
          toCheck.append(LineRow(name: substitute, detail: "Amount is an estimate, check it"))
        }
        continue
      }
      switch line.lineState {
      case .sufficient:
        fromKitchen.append(LineRow(name: name, detail: line.required?.displayText ?? ""))
      case .needsReconfirming:
        toCheck.append(
          LineRow(
            name: name,
            detail: "Amount is an estimate, check you have \(line.required?.displayText ?? "it")"))
      case .short:
        guard line.isRequired else {
          toCheck.append(LineRow(name: name, detail: "Optional, not in your kitchen"))
          continue
        }
        let shortGrams = line.short?.value ?? 0
        if let required = line.required, required.value - shortGrams > 0.5 {
          fromKitchen.append(
            LineRow(name: name, detail: PlanQuantity(value: required.value - shortGrams).displayText))
        }
        toBuy.append(LineRow(name: name, detail: line.short?.displayText ?? ""))
      case .quantityUnknown:
        toCheck.append(LineRow(name: name, detail: "No amount listed, check you have some"))
      case .assumedStaple:
        toCheck.append(
          LineRow(name: name, detail: "Assumed on hand · \(line.required?.displayText ?? "")"))
      }
    }

    let fit = fitText(dinner, shopFirst: shopFirst, buyCount: toBuy.count)
    var summary = "\(positionLabel). \(title)."
    if let minutes = dinner.timeMinutes { summary += " \(minutes) minutes." }
    summary += " \(servingsText). \(fit)."
    return DinnerCard(
      id: id, index: index, positionLabel: positionLabel, title: title, timeText: timeText,
      servings: dinner.servings, canChangeServings: true, canSwap: !shopFirst, fitText: fit,
      fromKitchen: fromKitchen, toBuy: toBuy, toCheck: toCheck, substitutions: substitutions,
      accessibilitySummary: summary)
  }

  /// "All 5 from your kitchen · 1 swap" only when every required line is sufficient;
  /// otherwise how many are covered and which to check. A shop-first dinner leads with the shop.
  private static func fitText(_ dinner: PlannedDinner, shopFirst: Bool, buyCount: Int) -> String {
    let required = dinner.lines.filter(\.isRequired)
    let covered = required.filter { $0.lineState == .sufficient }
    let swaps = required.filter { $0.swap != nil }.count
    if shopFirst {
      return buyCount == 1 ? "Needs a shop · 1 to buy" : "Needs a shop · \(buyCount) to buy"
    }
    guard !required.isEmpty else { return "No ingredient amounts listed" }
    if covered.count == required.count {
      var text = "All \(required.count) from your kitchen"
      if swaps > 0 { text += swaps == 1 ? " · 1 swap" : " · \(swaps) swaps" }
      return text
    }
    let attention = required.filter { $0.lineState != .sufficient }
      .map { PlanSheetText.ingredientName($0.name).lowercased() }
    let named = attention.prefix(2).joined(separator: " and ")
    let more = attention.count > 2 ? " and \(attention.count - 2) more" : ""
    return "\(covered.count) of \(required.count) from your kitchen · check \(named)\(more)"
  }

  // MARK: - Shopping list

  /// Things to buy first, alphabetically; items usually on hand after them.
  private static func rows(_ list: [ShoppingLine]) -> [ShoppingRow] {
    list
      .map { line in
        let name = PlanSheetText.ingredientName(line.name)
        let grams = Int(line.amount.value.rounded(.up))
        var label = "\(name), \(grams) \(grams == 1 ? "gram" : "grams")"
        if line.assumedStaple { label += ", you usually have this" }
        return ShoppingRow(
          id: line.ingredientID, name: name, grams: line.amount.value,
          amountText: line.amount.displayText, usuallyOnHand: line.assumedStaple,
          accessibilityLabel: label)
      }
      .sorted { a, b in
        if a.usuallyOnHand != b.usuallyOnHand { return !a.usuallyOnHand }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
      }
  }
}

/// Display text the plan sheet derives from stored names.
public enum PlanSheetText {
  /// Ingredient rows store names as the ingredient table spells them ("chicken_breast"). This
  /// matches the app's `Ingredient.displayName`: underscores become spaces, and an all-lowercase
  /// name is capitalized ("Chicken Breast"); a name with its own capitals is kept.
  public static func ingredientName(_ raw: String) -> String {
    let spaced = raw.replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespaces)
    return spaced == spaced.lowercased() ? spaced.localizedCapitalized : spaced
  }
}
