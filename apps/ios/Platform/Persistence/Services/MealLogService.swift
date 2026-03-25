import Foundation
import GRDB
import UIKit

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
    sourceRefPrefix: String? = nil
  ) throws -> Outcome {
    let imagePath = capturedImage.flatMap { try? imageStorageService.save($0) }
    return try logMeal(
      recipe: recipe,
      rating: rating,
      imagePath: imagePath,
      servingsConsumed: servingsConsumed,
      sourceRefPrefix: sourceRefPrefix
    )
  }

  @discardableResult
  func logMeal(
    recipe: Recipe,
    rating: Int? = nil,
    imagePath: String? = nil,
    servingsConsumed: Int,
    sourceRefPrefix: String? = nil
  ) throws -> Outcome {
    let safeServings = max(1, servingsConsumed)

    return try db.write { db in
      let recipeId = try recipeRepository.resolvePersistedRecipeID(in: db, for: recipe)
      let historyId = try personalizationService.recordCooking(
        in: db,
        recipeId: recipeId,
        rating: rating,
        imagePath: imagePath,
        servingsConsumed: safeServings
      )
      let sourceRef = normalizedSourceRef(sourceRefPrefix, recipeId: recipeId)
      let inventoryConsumption = try inventoryRepository.applyConsumption(
        in: db,
        recipeId: recipeId,
        servingsConsumed: safeServings,
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
