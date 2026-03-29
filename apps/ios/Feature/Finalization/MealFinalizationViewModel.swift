import Foundation
import Observation

@Observable
@MainActor
final class MealFinalizationViewModel {
  // MARK: - Input State

  var servings: Int = 1
  var rating: Int = 0
  var savedLeftovers: Bool = false
  var leftoverServings: Int = 1
  var wouldMakeAgain: Bool = true
  var photoPath: String?

  // MARK: - Derived

  var isSaving = false
  var didSave = false
  var errorMessage: String?

  // MARK: - Context

  let recipe: Recipe

  private let personalizationService: PersonalizationService
  private let inventoryRepository: InventoryRepository

  init(
    recipe: Recipe,
    defaultServings: Int = 1,
    personalizationService: PersonalizationService,
    inventoryRepository: InventoryRepository
  ) {
    self.recipe = recipe
    self.servings = defaultServings
    self.personalizationService = personalizationService
    self.inventoryRepository = inventoryRepository
  }

  // MARK: - Save

  func save() async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }

    do {
      guard let recipeId = recipe.id else {
        errorMessage = "Recipe has no ID."
        return
      }

      try personalizationService.recordCooking(
        recipeId: recipeId,
        rating: rating > 0 ? rating : nil,
        imagePath: photoPath,
        servingsConsumed: servings
      )

      try inventoryRepository.applyConsumption(
        recipeId: recipeId,
        servingsConsumed: servings
      )

      // TODO: Persist leftover tracking and repeat-preference once meal logging stores those fields.
      didSave = true
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
