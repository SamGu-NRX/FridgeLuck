import Foundation
import GRDB

enum MealLogError: LocalizedError {
  case invalidPortionMultiplier(Double)
  case planRecipeMismatch(planRecipeId: Int64, resolvedRecipeId: Int64)
  case invalidPlannedGrams(Double)

  var errorDescription: String? {
    switch self {
    case .invalidPortionMultiplier(let value):
      return "Portion multiplier must be a positive number, got \(value)."
    case .planRecipeMismatch(let planRecipeId, let resolvedRecipeId):
      return "The plan belongs to recipe \(planRecipeId), but the meal resolves to recipe \(resolvedRecipeId)."
    case .invalidPlannedGrams(let grams):
      return "Planned quantity \(grams) g is not a usable amount."
    }
  }
}

/// Coordinates meal logging so cooking history, swap, streak, inventory, and
/// nutrition-snapshot mutations are persisted atomically inside a single
/// database transaction.
///
/// When a consumption plan is passed, display, deduction preview and this deduction all
/// read that one object. The accepted plan is stored on the cooking_history row and is
/// deduplicated by its identity, so a retried log of the same plan reports the first
/// acceptance instead of deducting from the Kitchen a second time. Meal photos are saved
/// by callers (which own the image storage dependency) and passed in as a path.
final class MealLogService: Sendable {
  struct Outcome: Sendable {
    let historyId: Int64
    let recipeId: Int64
    let imagePath: String?
    let inventoryConsumption: [InventoryConsumptionResult]
  }

  private let db: DatabaseQueue
  private let recipeRepository: RecipeRepository
  private let personalizationService: PersonalizationService
  private let inventoryRepository: InventoryRepository
  /// Historical-nutrition writer (fl-next-historical-nutrition-r1), integrated through
  /// this seam: the accepted plan's applied grams and per-100g nutrition are frozen in
  /// the same transaction. Nil (tests, portable harness) keeps nutrition behavior
  /// catalog-live at read time for rows without snapshots.
  private let nutritionSnapshotting: (any MealNutritionSnapshotting)?

  init(
    db: DatabaseQueue,
    recipeRepository: RecipeRepository,
    personalizationService: PersonalizationService,
    inventoryRepository: InventoryRepository,
    nutritionSnapshotting: (any MealNutritionSnapshotting)? = nil
  ) {
    self.db = db
    self.recipeRepository = recipeRepository
    self.personalizationService = personalizationService
    self.inventoryRepository = inventoryRepository
    self.nutritionSnapshotting = nutritionSnapshotting
  }

  /// Logs a meal. With `plan` nil, the plan is built inside the transaction from live
  /// recipe rows — the Cooking Celebration path logs without a plan of its own.
  @discardableResult
  func logMeal(
    recipe: Recipe,
    rating: Int? = nil,
    imagePath: String? = nil,
    servingsConsumed: Int,
    portionMultiplier: Double = 1.0,
    swaps: [IngredientSwap] = [],
    sourceRefPrefix: String? = nil,
    plan proposedPlan: MealConsumptionPlan? = nil
  ) throws -> Outcome {
    let safeServings = max(1, servingsConsumed)
    guard portionMultiplier.isFinite, portionMultiplier > 0 else {
      throw MealLogError.invalidPortionMultiplier(portionMultiplier)
    }

    return try db.write { db in
      let recipeId = try recipeRepository.resolvePersistedRecipeID(in: db, for: recipe)

      // A plan already accepted under this identity is this exact meal; a retried log
      // callback reports the first acceptance instead of deducting twice.
      if let proposedPlan,
        let accepted = try Self.acceptedOutcome(
          forPlanIdentity: proposedPlan.identity, db: db, recipeId: recipeId)
      {
        return accepted
      }

      // Build or validate the plan inside the transaction so the deduction reads one
      // object the display and preview already agreed on.
      let plan: MealConsumptionPlan
      if let proposedPlan {
        guard proposedPlan.recipeId == recipeId else {
          throw MealLogError.planRecipeMismatch(
            planRecipeId: proposedPlan.recipeId,
            resolvedRecipeId: recipeId
          )
        }
        for line in proposedPlan.lines {
          guard line.plannedGrams.isFinite, line.plannedGrams >= 0 else {
            throw MealLogError.invalidPlannedGrams(line.plannedGrams)
          }
        }
        plan = proposedPlan.resetApplied()
      } else {
        plan = try MealConsumptionPlanBuilder.build(
          in: db,
          recipeId: recipeId,
          servingsConsumed: safeServings,
          portionMultiplier: portionMultiplier,
          swaps: swaps
        )
      }

      let historyId = try personalizationService.recordCooking(
        in: db,
        recipeId: recipeId,
        rating: rating,
        imagePath: imagePath,
        servingsConsumed: safeServings,
        portionMultiplier: portionMultiplier,
        swaps: swaps
      )
      // Per-meal attribution: several logs of one recipe each get their own ref.
      let sourceRef = Self.perMealSourceRef(sourceRefPrefix, recipeId: recipeId, historyId: historyId)
      let appliedLines = try inventoryRepository.applyPlanConsumption(
        in: db,
        plan: plan,
        sourceRef: sourceRef
      )

<<<<<<< HEAD
      var acceptedPlan = plan
      for (index, appliedLine) in appliedLines.enumerated() {
        acceptedPlan.lines[index].appliedGrams = appliedLine.appliedGrams
      }
      acceptedPlan.acceptedStreakDay = PersonalizationService.formatDate(Date())

      try db.execute(
        sql: """
          UPDATE cooking_history
          SET accepted_plan_json = ?, accepted_plan_identity = ?, accepted_revision = 1
          WHERE id = ?
          """,
        arguments: [
          acceptedPlan.persistedJSONString,
          acceptedPlan.identity,
          historyId,
        ]
      )

      // Historical-nutrition writer (fl-next-historical-nutrition-r1), integrated
      // through this seam: the first acceptance freezes the accepted plan's applied
      // grams and per-100g nutrition inside this same transaction. When the writer
      // is absent (portable harness, tests), rows keep live-catalog nutrition at
      // read time exactly as before this integration.
      if let snapshotting = nutritionSnapshotting {
        try snapshotting.captureSnapshot(in: db, historyId: historyId, plan: acceptedPlan, revision: 1)
      }

=======
      // Freeze the meal's nutrition from the catalog as it exists at logging
      // time, inside the same transaction as the history, swap, streak, and
      // inventory rows. Later catalog corrections cannot rewrite what was
      // consumed, and a failed log leaves no partial snapshot behind.
      try nutritionSnapshotService.captureSnapshot(
        in: db,
        historyId: historyId,
        recipeId: recipeId
      )

>>>>>>> 8988d2a (feat(ios): read meal history and Apple Health macros from frozen snapshots)
      return Outcome(
        historyId: historyId,
        recipeId: recipeId,
        imagePath: imagePath,
        inventoryConsumption: acceptedPlan.aggregatedConsumption()
      )
    }
  }

  /// The previously accepted log for a plan identity, reconstructed from what the first
  /// application stored, or nil when the identity has never been logged.
  private static func acceptedOutcome(
    forPlanIdentity identity: String, db: Database, recipeId: Int64
  ) throws -> Outcome? {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT id, image_path, accepted_plan_json
        FROM cooking_history
        WHERE accepted_plan_identity = ?
        LIMIT 1
        """,
      arguments: [identity]
    )
    guard let row,
      let planJSON: String = row["accepted_plan_json"],
      let plan = MealConsumptionPlan.decode(from: planJSON)
    else {
      return nil
    }
    return Outcome(
      historyId: row["id"] ?? 0,
      recipeId: recipeId,
      imagePath: row["image_path"] as String?,
      inventoryConsumption: plan.aggregatedConsumption()
    )
  }

  /// Consumption events carry this meal's own ref ('<prefix>:<recipeId>:<historyId>'), so
  /// later logs of the same recipe never share an audit trail with earlier ones.
  private static func perMealSourceRef(_ prefix: String?, recipeId: Int64, historyId: Int64)
    -> String
  {
    let stem = prefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return "\(stem.isEmpty ? "recipe" : stem):\(recipeId):\(historyId)"
  }
}
