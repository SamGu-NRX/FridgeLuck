import FLFeatureLogic
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

  private func makeIngredient(description: String? = nil) -> Ingredient {
    Ingredient(
      id: 41,
      name: "broccoli",
      calories: 89,
      protein: 3.7,
      carbs: 11.2,
      fat: 0.4,
      fiber: 2.6,
      sugar: 1.7,
      sodium: 0.385,
      typicalUnit: "1 cup (91g)",
      storageTip: "Refrigerate unwashed, in a loose bag.",
      pairsWith: "garlic, lemon",
      notes: nil,
      description: description,
      categoryLabel: "vegetable",
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
}
