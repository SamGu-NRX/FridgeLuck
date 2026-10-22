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

/// The catalog recipe a meal was made from: the revision its nutrition reports from, and
/// whether making it used Kitchen stock.
struct CatalogMealLog: Equatable, Sendable {
  enum Stock: Equatable, Sendable {
    /// Cooked here (the cook guide's completion): required lines come out of the Kitchen.
    case cookedHere
    /// Logged from a meal photo, which may show a plate this Kitchen never supplied, so
    /// stock stays as it is.
    case leaveKitchen
  }

  let id: String
  let revision: Int
  let stock: Stock

  /// The link for a caller that carries the catalog id and revision as separate optionals:
  /// nil when both are nil (a legacy meal). One without the other throws
  /// `CookingLogError.catalogIdentityIncomplete`, because the meal must link one exact
  /// revision or none.
  static func link(id: String?, revision: Int?, stock: Stock) throws -> CatalogMealLog? {
    switch (id, revision) {
    case (nil, nil): return nil
    case (let id?, let revision?): return CatalogMealLog(id: id, revision: revision, stock: stock)
    default: throw CookingLogError.catalogIdentityIncomplete
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
    /// Per-ingredient results. For a catalog meal these are `catalogLines` that reached stock.
    let inventoryConsumption: [InventoryConsumptionResult]
    /// One entry per required catalog line when a catalog meal was cooked here; empty for
    /// legacy meals and for catalog meals that leave the Kitchen alone.
    let catalogLines: [CatalogLineConsumption]
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
    catalog: CatalogMealLog? = nil
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
      catalog: catalog
    )
  }

  /// Logs a meal inside one transaction: history row, catalog identity link, taste
  /// events, and inventory consumption commit or roll back together. A catalog meal
  /// passes `catalog` so the history row links to the exact revision it was made at — the
  /// meal's nutrition reports through that frozen link, never through the currently
  /// installed revision. Its stock comes out through the ingredient bridge only when
  /// `catalog.stock` is `.cookedHere`; a legacy meal always takes its required ingredients.
  @discardableResult
  func logMeal(
    recipe: Recipe,
    rating: Int? = nil,
    imagePath: String? = nil,
    servingsConsumed: Int,
    portionMultiplier: Double = 1.0,
    swaps: [IngredientSwap] = [],
    sourceRefPrefix: String? = nil,
    catalog: CatalogMealLog? = nil
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
        catalogId: catalog?.id,
        catalogRevision: catalog?.revision
      )
      let sourceRef = normalizedSourceRef(sourceRefPrefix, recipeId: recipeId)

      // A catalog meal's `recipes` row only carries the title, usually with no ingredient
      // rows, so the legacy path takes nothing for it. What was made is the catalog recipe,
      // and its lines reach stock through the ingredient bridge.
      guard let catalog else {
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
          inventoryConsumption: inventoryConsumption,
          catalogLines: []
        )
      }
      let catalogLines: [CatalogLineConsumption]
      switch catalog.stock {
      case .cookedHere:
        catalogLines = try inventoryRepository.applyCatalogConsumption(
          in: db,
          catalogId: catalog.id,
          servingsConsumed: safeServings,
          portionMultiplier: portionMultiplier,
          sourceRef: sourceRef ?? "catalog:\(catalog.id)"
        )
      case .leaveKitchen:
        catalogLines = []
      }
      return Outcome(
        historyId: historyId,
        recipeId: recipeId,
        imagePath: imagePath,
        inventoryConsumption: catalogLines.compactMap(\.inventoryResult),
        catalogLines: catalogLines
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
