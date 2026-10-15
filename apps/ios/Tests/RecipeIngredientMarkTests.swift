import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// The preview's icon must agree with the results card about what's missing
/// (2026-10-07 walk: Cucumber listed as missing, shown with a green check).
final class RecipeIngredientMarkTests: XCTestCase {
  private let cucumber: Int64 = 41
  private let soySauce: Int64 = 7

  func testRequiredIngredientTheSearchLacksIsMissing() {
    XCTAssertEqual(
      RecipeIngredientMark.mark(
        ingredientID: cucumber, isRequired: true, isSubstituted: false,
        missingRequiredIDs: [cucumber]),
      .missing)
  }

  func testRequiredIngredientTheSearchHadIsHave() {
    XCTAssertEqual(
      RecipeIngredientMark.mark(
        ingredientID: soySauce, isRequired: true, isSubstituted: false,
        missingRequiredIDs: [cucumber]),
      .have)
  }

  /// Missing IDs cover required ingredients only, so an optional row never claims either way.
  func testOptionalIngredientIsOptionalWhetherOrNotItsIDIsListed() {
    for missing: Set<Int64> in [[], [cucumber]] {
      XCTAssertEqual(
        RecipeIngredientMark.mark(
          ingredientID: cucumber, isRequired: false, isSubstituted: false,
          missingRequiredIDs: missing),
        .optional)
    }
  }

  func testSubstitutedRowMakesNoAvailabilityClaim() {
    for missing: Set<Int64> in [[], [cucumber]] {
      XCTAssertEqual(
        RecipeIngredientMark.mark(
          ingredientID: cucumber, isRequired: true, isSubstituted: true,
          missingRequiredIDs: missing),
        .substituted)
    }
  }
}

/// The preview reads `missingIngredientIds` from the same search the results card shows, so the
/// marks must follow from what that search returns.
final class RecipePreviewAvailabilityTests: XCTestCase {
  func testNearMatchMarksFollowTheSearchedIngredients() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'cucumber', 15, 0.7, 3.6, 0.1),
            (2, 'soy sauce', 53, 8, 4.9, 0.6),
            (3, 'sesame oil', 884, 0, 0, 100);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Smacked cucumber', 10, 2, '1. Smack.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (1, 1, 1, 50, '50 g'), (1, 2, 1, 100, '100 g'), (1, 3, 0, 5, '5 g');
          """
      )
    }
    let nutrition = NutritionService(db: db)
    let repository = RecipeRepository(
      db: db,
      nutritionService: nutrition,
      healthScoringService: HealthScoringService(nutritionService: nutrition, db: db),
      personalizationService: PersonalizationService(db: db)
    )

    let scored = try XCTUnwrap(
      repository.findNearMatch(with: [2], profile: .default, maxMissingRequired: 1).first)
    let missing = Set(scored.missingIngredientIds)
    var marks: [Int64: RecipeIngredientMark] = [:]
    for item in try repository.ingredientsForRecipe(id: 1) {
      let id = try XCTUnwrap(item.ingredient.id)
      marks[id] = RecipeIngredientMark.mark(
        ingredientID: id, isRequired: item.quantity.isRequired, isSubstituted: false,
        missingRequiredIDs: missing)
    }

    XCTAssertEqual(marks, [1: .missing, 2: .have, 3: .optional])
  }
}
