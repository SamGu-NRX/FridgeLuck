import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// Hosted checks for the ingredient facts flow: the sheet's mapping from the real
/// `Ingredient` record into the presentation model, the AppPreferencesStore weight echo,
/// and the guarantee that every flow leaves the ingredient unchanged.
///
/// The pure math itself is covered offline by Tools/ingredient-facts-check, which compiles
/// the same logic source without a simulator.
@MainActor
final class IngredientFactsModelTests: XCTestCase {
  // MARK: - Fixtures

  private func makeIngredient(
    name: String = "broccoli",
    description: String? = nil,
    categoryLabel: String? = "vegetable",
    storageTip: String? = "Refrigerate unwashed, in a loose bag."
  ) -> Ingredient {
    Ingredient(
      id: 41,
      name: name,
      calories: 89,
      protein: 3.7,
      carbs: 11.2,
      fat: 0.4,
      fiber: 2.6,
      sugar: 1.7,
      sodium: 0.385,
      typicalUnit: "1 cup (91g)",
      storageTip: storageTip,
      pairsWith: "garlic, lemon",
      notes: nil,
      description: description,
      categoryLabel: categoryLabel,
      spriteGroup: "vegetable",
      spriteKey: "broccoli"
    )
  }

  private func makePreferences(unit: AppMeasurementUnit) -> AppPreferencesStore {
    let suiteName = "IngredientFactsModelTests.\(unit.rawValue)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(unit.rawValue, forKey: "appPref_measurementUnit")
    return AppPreferencesStore(defaults: defaults)
  }

  // MARK: - Sheet mapping

  /// A description-free record maps with no supplied description — there is no USDA or
  /// measured-data line to fall back on anywhere in the flow.
  func testDescriptionFreeIngredientMapsWithoutProvenanceClaim() {
    let sheet = IngredientDetailSheet(ingredient: makeIngredient())
    XCTAssertNil(sheet.facts.record.suppliedDescription)
    XCTAssertEqual(sheet.facts.reference.energyKilocalories, 89)
    XCTAssertEqual(sheet.facts.reference.sodiumMilligrams, 385)
  }

  /// A supplied description is carried verbatim, never reworded or endorsed.
  func testSuppliedDescriptionMapsVerbatim() {
    let sheet = IngredientDetailSheet(
      ingredient: makeIngredient(description: "A crisp green head, best steamed briefly."))
    XCTAssertEqual(
      sheet.facts.record.suppliedDescription, "A crisp green head, best steamed briefly.")
  }

  /// The description the hero renders is the record's supplied text exactly as stored:
  /// no rewording, trimming, or provenance label is added on either side of the mapping.
  func testSuppliedDescriptionCarriesThroughVerbatimForDisplay() {
    let text = "Sweet-tart and crisp; store cold and eat within two weeks."
    let sheet = IngredientDetailSheet(ingredient: makeIngredient(description: text))
    XCTAssertEqual(sheet.ingredient.description, text)
    XCTAssertEqual(sheet.facts.record.suppliedDescription, text)
  }

  /// The "Storage Tip" row shows the stored guidance exactly as entered.
  func testStorageGuidanceCarriesThroughVerbatimForDisplay() {
    let tip = "Keep at room temperature, away from direct sun."
    let sheet = IngredientDetailSheet(ingredient: makeIngredient(storageTip: tip))
    XCTAssertEqual(sheet.ingredient.storageTip, tip)
  }

  /// The hero title uses the record's display name (underscores spaced, plain names
  /// capitalized) and the category the sheet labels with carries through as stored.
  func testIngredientNameAndCategoryDisplayCarryThrough() {
    let sheet = IngredientDetailSheet(ingredient: makeIngredient())
    XCTAssertEqual(sheet.ingredient.displayName, "Broccoli")
    XCTAssertEqual(sheet.ingredient.categoryLabel, "vegetable")

    let underscored = IngredientDetailSheet(
      ingredient: makeIngredient(name: "green_onion", categoryLabel: "dairy_egg"))
    XCTAssertEqual(underscored.ingredient.displayName, "Green Onion")
    XCTAssertEqual(underscored.ingredient.categoryLabel, "dairy_egg")
  }

  // MARK: - Alias display source

  /// Aliases reach the sheet's "Also Known As" section through the repository query its
  /// load step runs: stored rows pass through in display order, and an ingredient with
  /// none gets an empty list, the case where the sheet hides the section entirely.
  func testAliasesPassThroughFromStoreToSheetDisplaySource() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, typical_unit) VALUES
            (41, 'broccoli', 89, 3.7, 11.2, 0.4, '1 cup (91g)')
          """)
      try db.execute(
        sql: """
          INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES
            (41, 'calabrese'), (41, 'broccolini'), (41, 'sprouting broccoli')
          """)
    }

    let repository = IngredientRepository(db: db)
    let loaded = try repository.aliases(for: 41)
    XCTAssertEqual(loaded, ["broccolini", "calabrese", "sprouting broccoli"])

    let noAliases = try repository.aliases(for: 999)
    XCTAssertEqual(noAliases, [])
  }

  // MARK: - Flows leave the ingredient unchanged

  /// Entering valid and invalid weights, resetting, and starting again must compare equal
  /// to the untouched record: the sheet is read-only over the ingredient.
  func testAllFlowsLeaveTheIngredientUnchanged() {
    let ingredient = makeIngredient(description: "Supplied context text.")
    let sheet = IngredientDetailSheet(ingredient: ingredient)
    let before = sheet.facts

    for text in ["250", "abc", "0", "-5", "1e309", "62.5", "", "100"] {
      _ = before.portionOutcome(forText: text)
    }

    // Rebuilding the sheet's model from the same ingredient must produce an equal model.
    let rebuilt = IngredientDetailSheet(ingredient: ingredient).facts
    XCTAssertEqual(before.record, rebuilt.record)
    XCTAssertEqual(before.reference, rebuilt.reference)

    // And the raw ingredient fields the sheet displays are still the stored ones.
    XCTAssertEqual(ingredient.calories, 89)
    XCTAssertEqual(ingredient.sodium, 0.385)
    XCTAssertEqual(ingredient.storageTip, "Refrigerate unwashed, in a loose bag.")
    XCTAssertEqual(ingredient.description, "Supplied context text.")
  }

  // MARK: - Weight presentation preference

  /// The entered weight echoes in the preferred unit while portions themselves are
  /// unit-independent — the model never sees the preference.
  func testWeightEchoFollowsPreferenceAndPortionsStayUnitIndependent() {
    let sheet = IngredientDetailSheet(ingredient: makeIngredient())
    let metric = makePreferences(unit: .metric)
    let imperial = makePreferences(unit: .imperial)

    XCTAssertEqual(metric.formatWeight(grams: 150), "150g")
    XCTAssertEqual(imperial.formatWeight(grams: 150), "5.3 oz")

    guard case .valid(let portion) = sheet.facts.portionOutcome(forText: "150") else {
      return XCTFail("150 g should be a valid portion")
    }
    // Same model, same values, whichever unit surrounds them.
    XCTAssertEqual(portion.energyKilocalories, 89 * 1.5, accuracy: 1e-9)
    XCTAssertEqual(portion.sodiumMilligrams, 385 * 1.5, accuracy: 1e-9)
  }

  /// Fractional input and the literal presets resolve through the production model.
  func testFractionalAndPresetWeightsResolve() {
    let sheet = IngredientDetailSheet(ingredient: makeIngredient())
    for text in ["50", "100", "250", "62.5"] {
      guard case .valid = sheet.facts.portionOutcome(forText: text) else {
        return XCTFail("\(text) g should be a valid portion")
      }
    }
    XCTAssertEqual(
      sheet.facts.portionOutcome(forText: "0"), .failed(IngredientFactsInputError.notPositive))
  }

  /// Each literal preset chip writes its amount as text into the field; through the model
  /// each resolves to the reference scaled to that weight, with the headline kcal and
  /// sodium lines rendered by the shared formatters the cards use.
  func testPresetPortionsProduceExpectedPortionText() {
    let sheet = IngredientDetailSheet(ingredient: makeIngredient())

    let expected: [
      (grams: Int, energy: Double, protein: Double, carbs: Double, fat: Double, fiber: Double,
        sugar: Double, sodium: Double, kcalText: String, sodiumText: String)
    ] = [
      (grams: 50, energy: 44.5, protein: 1.85, carbs: 5.6, fat: 0.2, fiber: 1.3, sugar: 0.85,
        sodium: 192.5, kcalText: "45 kcal", sodiumText: "193mg"),
      (grams: 100, energy: 89, protein: 3.7, carbs: 11.2, fat: 0.4, fiber: 2.6, sugar: 1.7,
        sodium: 385, kcalText: "89 kcal", sodiumText: "385mg"),
      (grams: 250, energy: 222.5, protein: 9.25, carbs: 28, fat: 1, fiber: 6.5, sugar: 4.25,
        sodium: 962.5, kcalText: "223 kcal", sodiumText: "963mg"),
    ]

    for row in expected {
      guard case .valid(let portion) = sheet.facts.portionOutcome(forText: String(row.grams))
      else {
        return XCTFail("\(row.grams) g should be a valid portion")
      }
      XCTAssertEqual(portion.grams, Double(row.grams))
      XCTAssertEqual(portion.energyKilocalories, row.energy, accuracy: 1e-9)
      XCTAssertEqual(portion.proteinGrams, row.protein, accuracy: 1e-9)
      XCTAssertEqual(portion.carbohydrateGrams, row.carbs, accuracy: 1e-9)
      XCTAssertEqual(portion.fatGrams, row.fat, accuracy: 1e-9)
      XCTAssertEqual(portion.fiberGrams, row.fiber, accuracy: 1e-9)
      XCTAssertEqual(portion.sugarGrams, row.sugar, accuracy: 1e-9)
      XCTAssertEqual(portion.sodiumMilligrams, row.sodium, accuracy: 1e-9)
      XCTAssertEqual(
        IngredientFactsQuantity.kilocalories(portion.energyKilocalories), row.kcalText)
      XCTAssertEqual(
        IngredientFactsQuantity.milligrams(portion.sodiumMilligrams), row.sodiumText)
    }
  }

  /// The portion card echoes the resolved weight through the preference store: whole and
  /// fractional grams in metric, ounces and the pound boundary in imperial.
  func testWeightEchoFormatsInBothMeasurementUnits() {
    let sheet = IngredientDetailSheet(ingredient: makeIngredient())
    let metric = makePreferences(unit: .metric)
    let imperial = makePreferences(unit: .imperial)

    guard case .valid(let smallPortion) = sheet.facts.portionOutcome(forText: "62.5") else {
      return XCTFail("62.5 g should be a valid portion")
    }
    XCTAssertEqual(metric.formatWeight(grams: smallPortion.grams), "63g")
    XCTAssertEqual(imperial.formatWeight(grams: smallPortion.grams), "2.2 oz")

    guard case .valid(let largePortion) = sheet.facts.portionOutcome(forText: "1000") else {
      return XCTFail("1000 g should be a valid portion")
    }
    XCTAssertEqual(metric.formatWeight(grams: largePortion.grams), "1000g")
    XCTAssertEqual(imperial.formatWeight(grams: largePortion.grams), "2.2 lb")
  }
}
