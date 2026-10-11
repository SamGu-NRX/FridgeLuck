import Foundation
import GRDB

// Integration seams for sibling feature streams. Neither implementation lives on this
// branch; both call sites keep the integration explicitly incomplete (documented in the
// PR handoff) instead of guessing at behavior the owning streams will define.

// MARK: - Historical nutrition snapshots (fl-next-historical-nutrition-r1)

/// Captures a versioned nutrition snapshot when an accepted meal state is persisted, so
/// later catalog edits can no longer rewrite history. INTEGRATED: NutritionSnapshotService
/// (cherry-picked from the owning branch) implements this seam with a plan-aware capture —
/// frozen lines carry the accepted plan's applied grams and per-100g nutrition — and is
/// injected at both acceptance (MealLogService) and correction (MealCorrectionService) in
/// AppDependencies. Passing nil keeps the pre-integration behavior for tests and the
/// portable harness.
protocol MealNutritionSnapshotting: Sendable {
  /// Called inside the same transaction that persists the accepted plan (first acceptance
  /// and every accepted correction). `revision` matches cooking_history.accepted_revision.
  func captureSnapshot(
    in db: Database, historyId: Int64, plan: MealConsumptionPlan, revision: Int
  ) throws
}

extension NutritionSnapshotService: MealNutritionSnapshotting {}

// MARK: - Inventory compensation (fl-next-inventory-maintenance-r1)

/// One ingredient's requested inventory adjustment for a deliberate correction or
/// deletion of a single meal.
struct InventoryCompensationDelta: Sendable, Equatable {
  /// The ingredient the meal's plan resolved to (the substitute when swapped).
  let ingredientId: Int64
  /// The recipe's own ingredient when a swap replaced it, nil otherwise.
  let originalIngredientId: Int64?
  /// Positive: return grams to the Kitchen (the meal consumed less than originally
  /// applied, or is being deleted). Negative: deduct additional grams. Requests are
  /// bounded by this meal's own accepted claims — never another meal's consumption.
  let grams: Double
}

/// Adjusts the Kitchen for one attributable correction/deletion operation. The owning
/// stream (fl-next-inventory-maintenance-r1) implements this as a per-meal, event-trail-
/// aware operation — never a blind stock restoration: returns are bounded by what this
/// meal itself consumed, so stock consumed by later meals is never replenished.
///
/// Integration is explicitly incomplete on this branch: while the seam is nil,
/// corrections and deletions adjust history, plans and streaks but leave inventory
/// untouched, and the outcome reports `compensationIntegrated == false`. No blind stock
/// updates are written as a stand-in.
protocol InventoryCompensating: Sendable {
  /// Applies the requested deltas inside the caller's transaction and returns the deltas
  /// it actually applied (shortages may cap additional deductions), so the accepted
  /// plan's applied grams track the Kitchen's real state.
  func compensate(
    in db: Database, deltas: [InventoryCompensationDelta], sourceRef: String
  ) throws -> [InventoryCompensationDelta]
}
