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
  /// The catalog identity this meal cooked at, when the recipe is a catalog recipe:
  /// the log links the exact `(catalogId, revision)`, so later revision bumps never
  /// rewrite its nutrition. nil logs the legacy integer-id row.
  private let catalogId: String?
  private let catalogRevision: Int?

  private let recipeRepository: RecipeRepository
  private let personalizationService: PersonalizationService
  private let inventoryRepository: InventoryRepository

  init(
    recipe: Recipe,
    defaultServings: Int = 1,
    catalogId: String? = nil,
    catalogRevision: Int? = nil,
    recipeRepository: RecipeRepository,
    personalizationService: PersonalizationService,
    inventoryRepository: InventoryRepository
  ) {
    self.recipe = recipe
    self.servings = defaultServings
    self.catalogId = catalogId
    self.catalogRevision = catalogRevision
    self.recipeRepository = recipeRepository
    self.personalizationService = personalizationService
    self.inventoryRepository = inventoryRepository
  }

  // MARK: - Save

  func save() async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }

    do {
      // Catalog entries carry no integer recipe id; the log lands on the legacy row the
      // meal resolves to (a title match, or a minimal row when none exists), and links
      // the (catalogId, revision) that was cooked so nutrition reports from the frozen
      // per-revision snapshot. Legacy recipes keep their integer id unchanged.
      let recipeId = try recipe.id ?? recipeRepository.resolvePersistedRecipeID(for: recipe)

      try personalizationService.recordCooking(
        recipeId: recipeId,
        rating: rating > 0 ? rating : nil,
        imagePath: photoPath,
        servingsConsumed: servings,
        recipeSource: TasteRecipeSource(recipeSource: recipe.source),
        catalogId: catalogId,
        catalogRevision: catalogRevision
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
