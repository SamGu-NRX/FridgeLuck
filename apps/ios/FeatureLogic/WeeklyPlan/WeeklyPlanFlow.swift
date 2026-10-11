import Foundation

// MARK: - Weekly plan flow (pure reducer)
//
// State transitions for proposing, reviewing, editing, accepting, and
// recomputing a weekly plan. No I/O: the caller supplies inputs, persists the
// returned store entry, and decides what the UI shows.
//
// Two product rules are encoded here and are not negotiable from the UI:
// 1. Staleness is detected by fingerprint; a stale plan is *shown* as stale
//    and never silently rewritten. Fixing it is the user's explicit recompute.
// 2. Any edit (slot replacement, slot removal) or recompute demotes an
//    accepted plan to a draft that must be accepted again. Acceptance never
//    silently survives a change.

public struct WeeklyPlanFlowState: Sendable, Equatable {
  public var entry: WeeklyPlanStoreEntry?
  /// True when the stored/derived plan's fingerprint differs from the current
  /// inputs. Only meaningful when `entry != nil`.
  public var isStale: Bool
  /// Set when the last explicit action was rejected, with a reason the UI can
  /// show verbatim. Cleared by any successful action.
  public var rejectionReason: String?

  public init(entry: WeeklyPlanStoreEntry? = nil, isStale: Bool = false, rejectionReason: String? = nil) {
    self.entry = entry
    self.isStale = isStale
    self.rejectionReason = rejectionReason
  }

  public var isAccepted: Bool { entry?.phase == .accepted }
  public var plan: WeeklyPlanRecord? { entry?.plan }
}

public enum WeeklyPlanFlow {

  /// Computes a fresh plan over the given inputs and returns it as a draft.
  /// The caller decides whether to persist it.
  public static func propose(inputs: WeeklyPlanInput, now: Date) -> WeeklyPlanFlowState {
    let result = WeeklyPlanEngine.plan(inputs)
    let record = WeeklyPlanRecord(
      result: result,
      candidateRecipeIds: inputs.recipes.map(\.id).sorted(),
      slots: inputs.slots)
    return WeeklyPlanFlowState(
      entry: WeeklyPlanStoreEntry(phase: .draft, plan: record, createdAt: now),
      isStale: false)
  }

  /// Accepts the current draft. Infeasible plans cannot be accepted — a plan
  /// that needs missing food is a shopping list, not a plan.
  public static func accept(state: WeeklyPlanFlowState, now: Date) -> WeeklyPlanFlowState {
    guard let entry = state.entry, entry.phase == .draft, entry.plan.isFeasible else {
      var rejected = state
      rejected.rejectionReason =
        state.entry?.plan.isFeasible == false
          ? "This plan is not feasible yet — resolve the shortages or recompute."
          : "There is no draft to accept."
      return rejected
    }
    var accepted = entry
    accepted.phase = .accepted
    accepted.acceptedAt = now
    return WeeklyPlanFlowState(entry: accepted, isStale: state.isStale)
  }

  /// Replaces the recipe in one slot. Feasibility is revalidated against the
  /// inputs' current stock; an edit that would break the plan is rejected with
  /// a reason. Success demotes acceptance to a draft.
  public static func editSlot(
    state: WeeklyPlanFlowState, slotId: Int64, newRecipeId: Int64, inputs: WeeklyPlanInput, now: Date
  ) -> WeeklyPlanFlowState {
    guard let entry = state.entry else {
      var rejected = state
      rejected.rejectionReason = "There is no plan to edit."
      return rejected
    }
    guard let recipe = inputs.recipes.first(where: { $0.id == newRecipeId }) else {
      var rejected = state
      rejected.rejectionReason = "Unknown recipe \(newRecipeId)."
      return rejected
    }
    guard let index = entry.plan.assignments.firstIndex(where: { $0.slotId == slotId }) else {
      var rejected = state
      rejected.rejectionReason = "Slot \(slotId) is not part of this plan."
      return rejected
    }

    let slotForEdit =
      entry.plan.slots.first(where: { $0.id == slotId })
      ?? WeeklyPlanSlot(id: slotId, label: entry.plan.assignments[index].slotLabel)

    let violations = validateEdit(
      currentAssignments: entry.plan.assignments, replacingSlot: slotForEdit,
      with: recipe, inputs: inputs)
    if let violation = violations.first {
      var rejected = state
      rejected.rejectionReason = WeeklyPlanViolationText.describe(violation)
      return rejected
    }

    var record = entry.plan
    record.assignments[index] = WeeklyPlanSlotAssignment(
      slotId: slotForEdit.id,
      slotLabel: slotForEdit.label,
      recipeId: recipe.id,
      recipeTitle: recipe.title,
      timeMinutes: recipe.timeMinutes,
      substitutions: [],
      servings: inputs.constraints.servingsPerMeal)
    // Edits keep the original fingerprint: staleness stays honest about what
    // the plan was computed from.
    record.isFeasible = true
    record.violations = []

    var nextEntry = entry
    nextEntry.plan = record
    if nextEntry.phase == .accepted { nextEntry.lastEditedAt = now }
    nextEntry.phase = .draft
    nextEntry.acceptedAt = nil

    return WeeklyPlanFlowState(entry: nextEntry, isStale: state.isStale)
  }

  /// Removes a slot from the plan. Dropping a slot can only free stock, so the
  /// remainder stays feasible; the shortages are rebuilt over what remains.
  /// Demotes acceptance to a draft.
  public static func removeSlot(
    state: WeeklyPlanFlowState, slotId: Int64, inputs: WeeklyPlanInput, now: Date
  ) -> WeeklyPlanFlowState {
    guard let entry = state.entry else {
      var rejected = state
      rejected.rejectionReason = "There is no plan to edit."
      return rejected
    }
    guard entry.plan.assignments.contains(where: { $0.slotId == slotId }) else {
      var rejected = state
      rejected.rejectionReason = "Slot \(slotId) is not part of this plan."
      return rejected
    }

    var record = entry.plan
    record.assignments.removeAll { $0.slotId == slotId }
    record.slots.removeAll { $0.id == slotId }

    let remaining: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)] = record.assignments.compactMap { a in
      guard let recipe = inputs.recipes.first(where: { $0.id == a.recipeId }) else { return nil }
      return (WeeklyPlanSlot(id: a.slotId, label: a.slotLabel), recipe)
    }
    if remaining.count == record.assignments.count, !remaining.isEmpty {
      let rows = WeeklyPlanConsumption.allocate(
        assignment: remaining, stock: inputs.stockByID, constraints: inputs.constraints)
      record.shortages = WeeklyPlanSearch.shortages(rows: rows, stock: inputs.stockByID)
    } else {
      record.shortages = []
    }

    var nextEntry = entry
    nextEntry.plan = record
    if nextEntry.phase == .accepted { nextEntry.lastEditedAt = now }
    nextEntry.phase = .draft
    nextEntry.acceptedAt = nil

    return WeeklyPlanFlowState(entry: nextEntry, isStale: state.isStale)
  }

  /// Explicit recomputation over fresh inputs. Never called implicitly: an
  /// accepted plan is only replaced when the user asks for this.
  public static func recompute(state: WeeklyPlanFlowState, inputs: WeeklyPlanInput, now: Date) -> WeeklyPlanFlowState {
    // Recomputation supersedes whatever existed, including acceptance.
    propose(inputs: inputs, now: now)
  }

  /// Recomputes staleness from the current inputs. Pure: derives the flag,
  /// touches nothing.
  public static func evaluateStaleness(state: WeeklyPlanFlowState, inputs: WeeklyPlanInput) -> WeeklyPlanFlowState {
    var next = state
    next.isStale =
      state.entry.map { $0.plan.fingerprint != WeeklyPlanFingerprint.compute(inputs) } ?? false
    return next
  }

  /// Clears the stored plan (start over / remove).
  public static func discard(state: WeeklyPlanFlowState) -> WeeklyPlanFlowState {
    WeeklyPlanFlowState(entry: nil, isStale: false)
  }

  /// Restores state at relaunch from the persisted entry, recomputing
  /// staleness against the inputs the app just loaded.
  public static func restore(entry: WeeklyPlanStoreEntry?, inputs: WeeklyPlanInput) -> WeeklyPlanFlowState {
    evaluateStaleness(state: WeeklyPlanFlowState(entry: entry, isStale: false), inputs: inputs)
  }

  /// Feasibility revalidation of one slot replacement: the other slots keep
  /// their planned recipes; the replaced slot gets the new recipe; the whole
  /// week is re-allocated against stock.
  private static func validateEdit(
    currentAssignments: [WeeklyPlanSlotAssignment], replacingSlot slot: WeeklyPlanSlot,
    with recipe: WeeklyPlanRecipe, inputs: WeeklyPlanInput
  ) -> [WeeklyPlanViolation] {
    if let ceiling = inputs.constraints.maxCookTimeMinutes, recipe.timeMinutes > ceiling {
      return [.cookTimeExceeded(recipeId: recipe.id, slotId: slot.id)]
    }
    if let required = inputs.constraints.requiredDietClass, recipe.dietClass != required {
      return [.dietClassMismatch(recipeId: recipe.id)]
    }
    for need in recipe.needs where !need.isOptional {
      let candidates = [need.ingredientId] + need.substitutes
      if candidates.allSatisfy({ inputs.constraints.excludedIngredientIds.contains($0) }) {
        return [.excludedIngredientRequired(recipeId: recipe.id, ingredientId: need.ingredientId)]
      }
    }

    let slotMap = Dictionary(uniqueKeysWithValues: inputs.slots.map { ($0.id, $0) })
    var planned: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)] = []
    for a in currentAssignments where a.slotId != slot.id {
      guard let keptSlot = slotMap[a.slotId],
        let keptRecipe = inputs.recipes.first(where: { $0.id == a.recipeId })
      else { continue }
      planned.append((keptSlot, keptRecipe))
    }
    planned.append((slot, recipe))

    let rows = WeeklyPlanConsumption.allocate(
      assignment: planned, stock: inputs.stockByID, constraints: inputs.constraints)
    if WeeklyPlanConsumption.isFeasible(rows: rows) { return [] }

    for row in rows where row.isRequired && (row.shortfallGrams > 1e-9 || row.unresolvableExcluded) {
      if row.unresolvableExcluded {
        return [.excludedIngredientRequired(recipeId: row.recipeId, ingredientId: row.ingredientId)]
      }
      if inputs.stockByID[row.ingredientId]?.quantityIsKnown != true {
        return [.unknownAmountCannotCover(ingredientId: row.ingredientId)]
      }
      return [.insufficientStock(ingredientId: row.ingredientId, shortfallGrams: row.shortfallGrams)]
    }
    return [.noEligibleRecipe(slotId: slot.id)]
  }
}
