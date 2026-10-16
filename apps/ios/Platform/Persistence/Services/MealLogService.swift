import Foundation
import GRDB
import UIKit

enum MealLogError: LocalizedError {
  case invalidPortionMultiplier(Double)

  var errorDescription: String? {
    switch self {
    case .invalidPortionMultiplier(let value):
      return "Portion multiplier must be a positive number, got \(value)."
    }
  }
}

/// Coordinates meal logging so cooking history + inventory mutations are persisted
/// atomically inside a single database transaction.
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
  private let imageStorageService: ImageStorageService

  init(
    db: DatabaseQueue,
    recipeRepository: RecipeRepository,
    personalizationService: PersonalizationService,
    inventoryRepository: InventoryRepository,
    imageStorageService: ImageStorageService
  ) {
    self.db = db
    self.recipeRepository = recipeRepository
    self.personalizationService = personalizationService
    self.inventoryRepository = inventoryRepository
    self.imageStorageService = imageStorageService
  }

  @discardableResult
  func logMeal(
    recipe: Recipe,
    rating: Int? = nil,
    capturedImage: UIImage? = nil,
    servingsConsumed: Int,
    portionMultiplier: Double = 1.0,
    swaps: [IngredientSwap] = [],
    sourceRefPrefix: String? = nil,
    catalogId: String? = nil,
    catalogRevision: Int? = nil
  ) throws -> Outcome {
    let imagePath = capturedImage.flatMap { try? imageStorageService.save($0) }
    return try logMeal(
      recipe: recipe,
      rating: rating,
      imagePath: imagePath,
      servingsConsumed: servingsConsumed,
      portionMultiplier: portionMultiplier,
      swaps: swaps,
      sourceRefPrefix: sourceRefPrefix,
      catalogId: catalogId,
      catalogRevision: catalogRevision
    )
  }

  /// Logs a meal inside one transaction: history row, catalog identity link, taste
  /// events, and inventory consumption commit or roll back together. A catalog cook
  /// passes `catalogId` + `catalogRevision` so the history row links to the exact
  /// revision that was cooked — the meal's nutrition reports through that frozen link,
  /// never through the currently installed revision. Both params or neither
  /// (`CookingLogError.catalogIdentityIncomplete`).
  @discardableResult
  func logMeal(
    recipe: Recipe,
    rating: Int? = nil,
    imagePath: String? = nil,
    servingsConsumed: Int,
    portionMultiplier: Double = 1.0,
    swaps: [IngredientSwap] = [],
    sourceRefPrefix: String? = nil,
    catalogId: String? = nil,
    catalogRevision: Int? = nil
  ) throws -> Outcome {
    let safeServings = max(1, servingsConsumed)
    guard portionMultiplier.isFinite, portionMultiplier > 0 else {
      throw MealLogError.invalidPortionMultiplier(portionMultiplier)
    }

    return try db.write { db in
      let recipeId = try recipeRepository.resolvePersistedRecipeID(in: db, for: recipe)
      let historyId = try personalizationService.recordCooking(
        in: db,
        recipeId: recipeId,
        rating: rating,
        imagePath: imagePath,
        servingsConsumed: safeServings,
        portionMultiplier: portionMultiplier,
        swaps: swaps,
        recipeSource: TasteRecipeSource(recipeSource: recipe.source),
        catalogId: catalogId,
        catalogRevision: catalogRevision
      )
      let sourceRef = normalizedSourceRef(sourceRefPrefix, recipeId: recipeId)
      let inventoryConsumption = try inventoryRepository.applyConsumption(
        in: db,
        recipeId: recipeId,
        servingsConsumed: safeServings,
        portionMultiplier: portionMultiplier,
        swaps: swaps,
        sourceRef: sourceRef
      )

      return Outcome(
        historyId: historyId,
        recipeId: recipeId,
        imagePath: imagePath,
        inventoryConsumption: inventoryConsumption
      )
    }
  }

  private func normalizedSourceRef(_ prefix: String?, recipeId: Int64) -> String? {
    guard let prefix = prefix?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty
    else {
      return nil
    }
    return "\(prefix):\(recipeId)"
  }
}
