import Foundation
import GRDB

/// Deliberate single-entry corrections and deletions, persisted as accepted revisions.
///
/// One call is one transaction over the meal's history row, its accepted plan and the
/// streak counts — plus, through the `InventoryCompensating` seam, the Kitchen. Both
/// sibling integrations (nutrition snapshots, inventory compensation) are explicitly
/// incomplete on this branch and are called only when their seam is provided.
///
/// Corrections and deletions never record confidence-study outcomes: only the original
/// successful log does.
final class MealCorrectionService: Sendable {
  /// What a correction or deletion did, including which integrations actually ran.
  struct RevisionOutcome: Sendable {
    /// The accepted revision after the operation. Unchanged on no-op retries.
    let acceptedRevision: Int
    /// True when the compensating seam ran (its result is reflected in the stored plan's
    /// applied grams). False means the inventory integration is not wired yet: inventory
    /// is untouched, nothing pretends otherwise.
    let compensationIntegrated: Bool
    /// The per-ingredient adjustment this operation requested from the seam.
    let requestedDeltas: [InventoryCompensationDelta]
    /// True when a row changed. Deletions of already-deleted meals report false.
    let changed: Bool
  }

  enum MealCorrectionError: LocalizedError {
    case unknownMeal(Int64)
    case mealWithoutAcceptedPlan(Int64)
    case correctedPlanIdentityMismatch(planIdentity: String, acceptedIdentity: String)
    case correctedPlanRecipeMismatch(planRecipeId: Int64, acceptedRecipeId: Int64)
    case swapSetChanged(lineKey: Int64)
    case invalidPlannedGrams(Double)

    var errorDescription: String? {
      switch self {
      case .unknownMeal(let historyId):
        return "Meal \(historyId) is not in the journal."
      case .mealWithoutAcceptedPlan(let historyId):
        return
          "Meal \(historyId) was logged before ingredient plans were kept, so its quantities cannot be corrected. Delete and re-log instead."
      case .correctedPlanIdentityMismatch(let planIdentity, let acceptedIdentity):
        return
          "The edited plan (identity \(planIdentity)) is not a revision of this meal's accepted plan (identity \(acceptedIdentity))."
      case .correctedPlanRecipeMismatch(let planRecipeId, let acceptedRecipeId):
        return
          "The edited plan belongs to recipe \(planRecipeId), but the meal recorded recipe \(acceptedRecipeId)."
      case .swapSetChanged(let lineKey):
        return
          "Corrections change quantities only. The ingredient behind line \(lineKey) was swapped differently when the meal was logged."
      case .invalidPlannedGrams(let grams):
        return "Planned quantity \(grams) g is not a usable amount."
      }
    }
  }

  private let db: DatabaseQueue
  /// Unimplemented on this branch — see `InventoryCompensating`.
  private let inventoryCompensating: (any InventoryCompensating)?
  /// Unimplemented on this branch — see `MealNutritionSnapshotting`.
  private let nutritionSnapshotting: (any MealNutritionSnapshotting)?

  init(
    db: DatabaseQueue,
    inventoryCompensating: (any InventoryCompensating)? = nil,
    nutritionSnapshotting: (any MealNutritionSnapshotting)? = nil
  ) {
    self.db = db
    self.inventoryCompensating = inventoryCompensating
    self.nutritionSnapshotting = nutritionSnapshotting
  }

  // MARK: - Correction

  /// Corrects one logged meal: new per-ingredient quantities (a revision of its accepted
  /// plan), optionally a new cooked day. Date edits change the day only — the original
  /// time of day is preserved — and streak counts move with the local day. Nothing here
  /// records a confidence-study outcome.
  @discardableResult
  func correctMeal(
    historyId: Int64, correctedPlan: MealConsumptionPlan, editedCookedAt: Date? = nil
  ) throws -> RevisionOutcome {
    try db.write { db in
      // 1. The accepted state being revised. Rows logged before plans existed have no
      //    accepted state to revise — correcting them is refused, deletion still works.
      let current = try Self.loadAcceptedState(db: db, historyId: historyId)
      guard let acceptedPlan = current.plan else {
        throw MealCorrectionError.mealWithoutAcceptedPlan(historyId)
      }

      // 2. The corrected plan must be a revision of this meal's plan: same recipe, same
      //    identity, same ingredient lines (swap set fixed from the original log).
      try Self.validate(correctedPlan: correctedPlan, accepted: acceptedPlan)
      for line in correctedPlan.lines {
        guard line.plannedGrams.isFinite, line.plannedGrams >= 0 else {
          throw MealCorrectionError.invalidPlannedGrams(line.plannedGrams)
        }
      }

      // 3. New cooked date: date-only edits keep the original time of day. A same-day
      //    edit is not a date change at all (no sub-second drift, so retries stay no-ops).
      let newCookedAt: Date
      if let editedCookedAt,
        PersonalizationService.formatDate(editedCookedAt)
          != PersonalizationService.formatDate(current.cookedAt)
      {
        newCookedAt = Self.cookedAt(preservingOriginalTime: current.cookedAt, newDay: editedCookedAt)
      } else {
        newCookedAt = current.cookedAt
      }

      // 4. Nothing changed (a retried callback with the same request) → no writes.
      let noOp =
        acceptedPlan.servingsConsumed == correctedPlan.servingsConsumed
        && acceptedPlan.portionMultiplier == correctedPlan.portionMultiplier
        && acceptedPlan.lines.map(\.lineKey) == correctedPlan.lines.map(\.lineKey)
        && zip(acceptedPlan.lines, correctedPlan.lines).allSatisfy {
          abs($0.plannedGrams - $1.plannedGrams) < 1e-9
        }
        && newCookedAt == current.cookedAt
      if noOp {
        return RevisionOutcome(
          acceptedRevision: current.revision, compensationIntegrated: false,
          requestedDeltas: [], changed: false)
      }

      let newRevision = current.revision + 1

      // 5. Per-ingredient deltas vs what the Kitchen actually lost to this meal so far:
      //    positive requests a return of this meal's own grams, negative an additional
      //    deduction. Bounded by this meal's claims by construction (applied grams only).
      let deltas = Self.deltas(from: acceptedPlan, to: correctedPlan)
      let sourceRef = "meal_correction:\(historyId):\(newRevision)"

      // 6. Compensation. While the seam is unimplemented this stays nil: the accepted
      //    applied grams are kept unchanged (the Kitchen's reality), and the outcome
      //    reports the integration as incomplete. No blind stock updates are written.
      var updatedPlan = correctedPlan
      var compensationIntegrated = false
      if let compensating = inventoryCompensating {
        let applied = try compensating.compensate(in: db, deltas: deltas, sourceRef: sourceRef)
        updatedPlan = Self.distributeApplied(
          plan: correctedPlan, accepted: acceptedPlan,
          perIngredientApplied: Self.gramsByIngredient(applied))
        compensationIntegrated = true
      } else {
        updatedPlan = Self.keepAcceptedAppliedGrams(corrected: correctedPlan, accepted: acceptedPlan)
      }

      // 7. Persist the accepted revision.
      let newStreakDay = PersonalizationService.formatDate(newCookedAt)
      updatedPlan.acceptedStreakDay = newStreakDay
      try db.execute(
        sql: """
          UPDATE cooking_history
          SET accepted_plan_json = ?, accepted_revision = ?, servings_consumed = ?,
              portion_multiplier = ?, cooked_at = ?
          WHERE id = ?
          """,
        arguments: [
          updatedPlan.persistedJSONString, newRevision, correctedPlan.servingsConsumed,
          correctedPlan.portionMultiplier, newCookedAt, historyId,
        ])

      // 8. Streak counts move with the local day.
      try Self.moveStreakCount(
        db: db, fromDay: acceptedPlan.acceptedStreakDay, toDay: newStreakDay)

      // 9. Nutrition snapshot seam (unimplemented on this branch).
      if let snapshotting = nutritionSnapshotting {
        try snapshotting.captureSnapshot(in: db, historyId: historyId, plan: updatedPlan, revision: newRevision)
      }

      return RevisionOutcome(
        acceptedRevision: newRevision, compensationIntegrated: compensationIntegrated,
        requestedDeltas: deltas, changed: true)
    }
  }

  // MARK: - Deletion

  /// Deletes one logged meal: returns this meal's own consumed grams to the Kitchen
  /// through the compensating seam, moves the streak day count down (floor 0) and deletes
  /// exactly one history row — swaps cascade, other meals, events and lots are untouched.
  /// Deleting an already-deleted meal is a no-op (nothing thrown, nothing written).
  @discardableResult
  func deleteMeal(historyId: Int64) throws -> RevisionOutcome {
    try db.write { db in
      guard let current = try Self.maybeLoadAcceptedState(db: db, historyId: historyId) else {
        return RevisionOutcome(
          acceptedRevision: 0, compensationIntegrated: false, requestedDeltas: [], changed: false)
      }

      // This meal's own claims, positive = what the Kitchen should get back. Meals logged
      // before plans existed have no accepted plan, so no claims are computable here; the
      // owning stream can reconstruct them from the per-meal event trail when it lands.
      let deltas: [InventoryCompensationDelta]
      if let plan = current.plan {
        deltas = Self.deleteDeltas(for: plan)
      } else {
        deltas = []
      }

      var compensationIntegrated = false
      if let compensating = inventoryCompensating, !deltas.isEmpty {
        _ = try compensating.compensate(
          in: db, deltas: deltas, sourceRef: "meal_delete:\(historyId)")
        compensationIntegrated = true
      }

      if let streakDay = current.plan?.acceptedStreakDay
          ?? (current.plan == nil ? PersonalizationService.formatDate(current.cookedAt) : nil) {
        try Self.adjustStreak(db: db, day: streakDay, by: -1)
      }

      try db.execute(sql: "DELETE FROM cooking_history WHERE id = ?", arguments: [historyId])
      return RevisionOutcome(
        acceptedRevision: current.revision, compensationIntegrated: compensationIntegrated,
        requestedDeltas: deltas, changed: true)
    }
  }

  // MARK: - Accepted-state loading

  private struct AcceptedState {
    var revision: Int
    var cookedAt: Date
    var plan: MealConsumptionPlan?
  }

  private static func maybeLoadAcceptedState(db: Database, historyId: Int64) throws -> AcceptedState? {
    let row = try Row.fetchOne(
      db,
      sql: "SELECT cooked_at, accepted_plan_json, accepted_revision FROM cooking_history WHERE id = ?",
      arguments: [historyId])
    guard let row else { return nil }
    let cookedAt: Date? = row["cooked_at"]
    let revision: Int = row["accepted_revision"] ?? 1
    return AcceptedState(
      revision: revision, cookedAt: cookedAt ?? Date(),
      plan: MealConsumptionPlan.decode(from: row["accepted_plan_json"]))
  }

  private static func loadAcceptedState(db: Database, historyId: Int64) throws -> AcceptedState {
    guard let state = try maybeLoadAcceptedState(db: db, historyId: historyId) else {
      throw MealCorrectionError.unknownMeal(historyId)
    }
    return state
  }

  // MARK: - Validation and arithmetic

  private static func validate(
    correctedPlan: MealConsumptionPlan, accepted: MealConsumptionPlan
  ) throws {
    guard correctedPlan.recipeId == accepted.recipeId else {
      throw MealCorrectionError.correctedPlanRecipeMismatch(
        planRecipeId: correctedPlan.recipeId, acceptedRecipeId: accepted.recipeId)
    }
    guard correctedPlan.identity == accepted.identity else {
      throw MealCorrectionError.correctedPlanIdentityMismatch(
        planIdentity: correctedPlan.identity, acceptedIdentity: accepted.identity)
    }
    // Swap set fixed from the original log: the same ingredient lines, in the same
    // resolution. Quantities are the editable part.
    let acceptedByKey = Dictionary(
      accepted.lines.map { ($0.lineKey, $0) }, uniquingKeysWith: { _, last in last })
    guard correctedPlan.lines.count == accepted.lines.count else {
      throw MealCorrectionError.swapSetChanged(lineKey: -1)
    }
    for line in correctedPlan.lines {
      guard let acceptedLine = acceptedByKey[line.lineKey],
        acceptedLine.resolvedIngredientId == line.resolvedIngredientId
      else {
        throw MealCorrectionError.swapSetChanged(lineKey: line.lineKey)
      }
    }
  }

  /// Deltas per resolved ingredient: what this meal's Kitchen footprint should become
  /// (positive = return, negative = additional deduction), aggregated across lines that
  /// resolve to the same ingredient.
  static func deltas(
    from accepted: MealConsumptionPlan, to corrected: MealConsumptionPlan
  ) -> [InventoryCompensationDelta] {
    aggregateDeltas(
      accepted.lines.map { ($0.resolvedIngredientId, $0.originalIngredientId, $0.appliedGrams) },
      corrected.lines.map { ($0.resolvedIngredientId, $0.originalIngredientId, $0.plannedGrams) })
  }

  /// What deleting the meal gives back: the meal's own applied consumption, positive.
  static func deleteDeltas(for plan: MealConsumptionPlan) -> [InventoryCompensationDelta] {
    deltas(from: plan, to: plan.zeroedPlan())
  }

  private static func aggregateDeltas(
    _ from: [(Int64, Int64?, Double)], _ to: [(Int64, Int64?, Double)]
  ) -> [InventoryCompensationDelta] {
    var order: [Int64] = []
    var byId: [Int64: (original: Int64?, grams: Double)] = [:]
    for (id, original, grams) in from {
      if byId[id] == nil { order.append(id) }
      byId[id] = (original, (byId[id]?.grams ?? 0) + grams)
    }
    for (id, original, grams) in to {
      if byId[id] == nil { order.append(id) }
      byId[id] = (original, (byId[id]?.grams ?? 0) - grams)
    }
    return order.compactMap { id in
      guard let entry = byId[id], abs(entry.grams) > 1e-9 else { return nil }
      return InventoryCompensationDelta(
        ingredientId: id, originalIngredientId: entry.original, grams: entry.grams)
    }
  }

  /// While compensation is not integrated, the accepted applied grams keep describing
  /// what the Kitchen actually lost to this meal so far.
  private static func keepAcceptedAppliedGrams(
    corrected: MealConsumptionPlan, accepted: MealConsumptionPlan
  ) -> MealConsumptionPlan {
    var plan = corrected
    let appliedByKey = Dictionary(
      accepted.lines.map { ($0.lineKey, $0.appliedGrams) }, uniquingKeysWith: { _, last in last })
    for index in plan.lines.indices {
      plan.lines[index].appliedGrams = appliedByKey[plan.lines[index].lineKey] ?? 0
    }
    return plan
  }

  /// Spreads the per-ingredient compensation the seam actually applied back onto lines,
  /// on top of what the Kitchen had already lost to this meal: net line applied grams =
  /// accepted applied − the line's share of the applied deltas.
  static func distributeApplied(
    plan: MealConsumptionPlan, accepted: MealConsumptionPlan,
    perIngredientApplied: [Int64: Double]
  ) -> MealConsumptionPlan {
    var updated = plan
    let acceptedByKey = Dictionary(
      accepted.lines.map { ($0.lineKey, $0.appliedGrams) }, uniquingKeysWith: { _, last in last })
    for index in updated.lines.indices {
      let line = updated.lines[index]
      let total = perIngredientApplied[line.resolvedIngredientId] ?? 0
      let plannedTotal = updated.lines
        .filter { $0.resolvedIngredientId == line.resolvedIngredientId }
        .map(\.plannedGrams)
        .reduce(0, +)
      let share = plannedTotal > 0 ? line.plannedGrams / plannedTotal : 0
      let acceptedApplied = acceptedByKey[line.lineKey] ?? 0
      updated.lines[index].appliedGrams = max(0, acceptedApplied - total * share)
    }
    return updated
  }

  private static func gramsByIngredient(_ deltas: [InventoryCompensationDelta]) -> [Int64: Double] {
    var byId: [Int64: Double] = [:]
    for delta in deltas {
      byId[delta.ingredientId] = (byId[delta.ingredientId] ?? 0) + delta.grams
    }
    return byId
  }

  // MARK: - Dates and streaks

  /// A date-only edit: the new day with the original time of day preserved. Falls back
  /// to the new day if the calendar cannot combine them.
  static func cookedAt(preservingOriginalTime original: Date, newDay: Date) -> Date {
    Calendar.current.date(
      bySettingHour: Calendar.current.component(.hour, from: original),
      minute: Calendar.current.component(.minute, from: original),
      second: Calendar.current.component(.second, from: original),
      of: newDay
    ) ?? newDay
  }

  private static func adjustStreak(db: Database, day: String, by count: Int) throws {
    guard count != 0 else { return }
    let existing = try Streak.fetchOne(db, key: day)
    let newCount = max(0, (existing?.mealsCookedCount ?? 0) + count)
    if var streak = existing {
      streak.mealsCookedCount = newCount
      try streak.update(db)
    } else if newCount > 0 {
      // A corrected-to day that never had a row gets one.
      try Streak(date: day, mealsCookedCount: newCount).insert(db)
    }
  }

  /// Moves one meal's streak count between local days; a moved-from day never drops
  /// below zero, and a moved-to day's row is inserted when missing.
  private static func moveStreakCount(db: Database, fromDay: String?, toDay: String) throws {
    guard fromDay != toDay else { return }
    if let fromDay {
      try adjustStreak(db: db, day: fromDay, by: -1)
    }
    try adjustStreak(db: db, day: toDay, by: +1)
  }
}

extension MealConsumptionPlan {
  /// A proposal matching `rescaled` shape but with every line at zero grams — used to
  /// express "this meal consumed nothing" when computing deletion deltas.
  func zeroedPlan() -> MealConsumptionPlan {
    var plan = self
    for index in plan.lines.indices {
      plan.lines[index].plannedGrams = 0
    }
    return plan
  }
}
