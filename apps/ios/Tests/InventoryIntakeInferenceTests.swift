import Foundation
import XCTest

@testable import FridgeLuck

/// Characterization and regression tests for the intake helpers in
/// `InventoryIntakeService` — location inference and gram estimation from
/// detection labels and bundled storage tips.
///
/// These tests pin the matching semantics deliberately:
/// - Names match whole words (plural-aware), so `eggplant` never rides the egg
///   rule and `peanut` never rides the pea rule.
/// - A storage tip that mentions a recognized storage word wins over the name
///   ("Refrigerate after opening" files soy sauce in the fridge even though the
///   name says pantry); its FIRST storage word is treated as the primary
///   instruction ("Refrigerate or freeze" means fridge, "Cool dark place, not
///   fridge" means pantry). A tip that names no storage word is ignored.
/// - When the tip is missing or unrecognized, the name decides; the helper no
///   longer returns `.unknown` just because the tip was absent.
/// - Grams are tier heuristics measured against real kitchen units, not
///   measured masses; snake_case detection labels and spaced display names are
///   matched identically.
///
/// The core-50 tables characterize every bundled core ingredient under its own
/// bundled tip and under name-only fallback. Some of those storages are
/// genuinely contested (tomato, lemon, banana, avocado, corn): where real
/// guidance is "ripen at room temp, then refrigerate," the pinned value is the
/// helper's first-storage-word rule, and the note says so rather than
/// presenting the choice as universal food guidance.
final class InventoryIntakeInferenceTests: XCTestCase {

  // MARK: - Demonstrated collisions (whole-word + explicit exceptions)

  func testNameCollisionsAreFixed() throws {
    // (label, expected name-only location, expected grams, why)
    let rows: [(label: String, location: InventoryStorageLocation?, grams: Double?, why: String)]
      = [
        ("olive oil", .pantry, 30, "stability: the name rule already knew this one"),
        ("goat cheese", .fridge, 120, "must not ride the oat pantry rule and the dry-goods rule"),
        ("eggplant", .fridge, 120, "must not ride the egg 50 g rule"),
        ("fresh green beans", .fridge, 120, "fresh pods are not the dried-bean rule"),
        ("green beans", .fridge, 120, "same collision without the 'fresh' prefix"),
        ("dried beans", .pantry, 180, "the dry-bean rule keeps applying to dried beans"),
        ("red pepper flakes", .pantry, 30, "a spice jar is not a fresh pepper"),
        ("peanut", .pantry, 180, "whole-word pea keeps peanuts out of the pea rule"),
        ("peach", .fridge, 120, "whole-word pea keeps peaches out of the pea rule"),
        ("peas", nil, 180, "actual peas keep their existing dry-goods tier"),
      ]
    for row in rows {
      if let location = row.location {
        XCTAssertEqual(
          InventoryIntakeService.inferLocation(forName: row.label), location,
          "\(row.label): \(row.why)")
      }
      if let grams = row.grams {
        XCTAssertEqual(
          InventoryIntakeService.estimateGrams(forName: row.label), grams, "\(row.label): \(row.why)")
      }
    }
  }

  // MARK: - Tip presence and precedence

  func testMissingTipFallsBackToTheName() throws {
    // The old helper returned .unknown whenever storageTip was absent.
    XCTAssertEqual(
      InventoryIntakeService.inferLocation(for: ingredient(name: "olive_oil", storageTip: nil)),
      .pantry)
    XCTAssertEqual(
      InventoryIntakeService.inferLocation(for: ingredient(name: "goat cheese", storageTip: nil)),
      .fridge)
    XCTAssertEqual(
      InventoryIntakeService.inferLocation(for: ingredient(name: "peach", storageTip: nil)), .fridge)
  }

  func testUnrecognizedTipFallsBackToTheName() throws {
    XCTAssertEqual(
      InventoryIntakeService.inferLocation(
        for: ingredient(name: "rice", storageTip: "Store in airtight container")),
      .pantry)
  }

  func testRecognizedTipBeatsTheName() throws {
    // A tip with a recognized storage word wins even when the name disagrees.
    XCTAssertEqual(
      InventoryIntakeService.inferLocation(
        for: ingredient(name: "milk", storageTip: "Cool dark place, sealed")),
      .pantry)
    XCTAssertEqual(
      InventoryIntakeService.inferLocation(
        for: ingredient(name: "olive_oil", storageTip: "Refrigerate after opening")),
      .fridge)
  }

  func testTipMeansItsFirstStorageWord() throws {
    // (tip, name that would infer differently, expected, why)
    let rows: [(tip: String, name: String, expected: InventoryStorageLocation, why: String)] = [
      ("Cool dark place, not fridge", "potato", .pantry,
       "the tip rules the fridge out; its first storage word wins"),
      ("Refrigerate or freeze", "ginger", .fridge,
       "refrigerate is primary; freeze is the longer-term option"),
      ("Refrigerate 2 days, freeze longer", "salmon", .fridge,
       "refrigerate is primary; freeze is for longer storage"),
      ("Room temp 3-5 days, freeze for longer", "bread", .pantry,
       "room temp is primary; freeze is for longer storage"),
      ("Room temp 1 week, freeze longer", "tortilla", .pantry,
       "room temp is primary; freeze is the longer-term option"),
      ("Use within 2 days or freeze", "chicken_breast", .freezer,
       "ambiguous: the 2-day clock implies the fridge; the tip's only storage word is freeze"),
      ("Keep frozen until use", "frozen_peas", .freezer,
       "'frozen' is recognized even without the word 'freeze'"),
    ]
    for row in rows {
      XCTAssertEqual(
        InventoryIntakeService.inferLocation(for: ingredient(name: row.name, storageTip: row.tip)),
        row.expected, "\(row.tip): \(row.why)")
    }
  }

  // MARK: - Plurals and OCR-style labels

  func testPluralAndOCRLabelsStayOnTier() throws {
    let rows: [(label: String, location: InventoryStorageLocation?, grams: Double?)] = [
      ("eggs", .fridge, 50),
      ("tomatoes", .fridge, 120),
      ("peaches", .fridge, 120),
      ("2% milk", .fridge, 240),
      ("oats", .pantry, 180),
      ("oatmeal", .pantry, 180),
      ("garbanzo beans", .pantry, 180),
      ("frozen peas", .freezer, 180),
      ("bell_pepper", .fridge, 120),
      ("green onion", .fridge, 40),
    ]
    for row in rows {
      if let location = row.location {
        XCTAssertEqual(InventoryIntakeService.inferLocation(forName: row.label), location, row.label)
      }
      if let grams = row.grams {
        XCTAssertEqual(InventoryIntakeService.estimateGrams(forName: row.label), grams, row.label)
      }
    }
  }

  // MARK: - Core-50 characterization (bundled tips)

  /// Every core bundled ingredient, under the exact storage tip shipped in
  /// `data.json`. Grams come from the name tier either way; a tip never
  /// changes them.
  func testCoreFiftyWithBundledTips() throws {
    // (name, bundled tip, expected location, expected grams, note)
    let rows: [(name: String, tip: String, location: InventoryStorageLocation, grams: Double, note: String)]
      = [
        ("Egg", "Refrigerate, use within 3 weeks", .fridge, 50, ""),
        ("Rice", "Store in airtight container", .pantry, 180, "unrecognized tip falls back to the name"),
        ("Soy Sauce", "Refrigerate after opening", .fridge, 30,
         "tip wins over the pantry 'sauce' name rule; unopened bottles are shelf-stable"),
        ("Chicken Breast", "Use within 2 days or freeze", .freezer, 150,
         "ambiguous: the 2-day clock implies the fridge; the tip's only storage word is freeze"),
        ("Onion", "Store in cool, dark place", .pantry, 120, ""),
        ("Garlic", "Store in cool, dry place", .pantry, 20, ""),
        ("Tomato", "Store at room temperature", .pantry, 120,
         "contested: counter-ripen then refrigerate; the tip's first storage word wins"),
        ("Bell Pepper", "Refrigerate in crisper drawer", .fridge, 120, ""),
        ("Pasta", "Dry: cool, dark place", .pantry, 180, ""),
        ("Potato", "Cool dark place, not fridge", .pantry, 120,
         "the tip rules the fridge out; its first storage word wins"),
        ("Carrot", "Refrigerate in bag", .fridge, 120, ""),
        ("Cheese", "Wrap tightly, refrigerate", .fridge, 120, ""),
        ("Milk", "Refrigerate, use by date", .fridge, 240, ""),
        ("Butter", "Refrigerate or freeze", .fridge, 120,
         "refrigerate is primary; freeze is the longer-term option"),
        ("Bread", "Room temp 3-5 days, freeze for longer", .pantry, 60,
         "room temp is primary; freeze is for longer storage"),
        ("Olive Oil", "Cool dark place, sealed", .pantry, 30, ""),
        ("Lemon", "Room temp 1 week, fridge 4 weeks", .pantry, 120,
         "contested: room temp first, then fridge; the tip's first storage word wins"),
        ("Mushroom", "Refrigerate in paper bag", .fridge, 120, ""),
        ("Spinach", "Refrigerate, use within 5 days", .fridge, 40, ""),
        ("Banana", "Room temp until ripe, then fridge", .pantry, 120,
         "contested: ripen at room temp, then fridge; the tip's first storage word wins"),
        ("Green Onion", "Refrigerate in glass of water", .fridge, 40, ""),
        ("Sesame Oil", "Cool dark place", .pantry, 30, ""),
        ("Tofu", "Refrigerate in water, change daily", .fridge, 150, ""),
        ("Broccoli", "Refrigerate, use within 5 days", .fridge, 120, ""),
        ("Cucumber", "Refrigerate, use within 1 week", .fridge, 120, ""),
        ("Avocado", "Room temp until ripe, then fridge", .pantry, 120,
         "contested: ripen at room temp, then fridge; the tip's first storage word wins"),
        ("Black Beans", "Canned: pantry 2 years", .pantry, 180, ""),
        ("Tortilla", "Room temp 1 week, freeze longer", .pantry, 60,
         "room temp is primary; freeze is the longer-term option"),
        ("Lime", "Room temp 1 week, fridge 4 weeks", .pantry, 120,
         "contested: room temp first, then fridge; the tip's first storage word wins"),
        ("Ginger", "Refrigerate or freeze", .fridge, 20,
         "refrigerate is primary; freeze is the longer-term option"),
        ("Oats", "Cool dry place, sealed", .pantry, 180, ""),
        ("Yogurt", "Refrigerate, check date", .fridge, 240, ""),
        ("Honey", "Room temp, sealed", .pantry, 30, ""),
        ("Corn", "Refrigerate, use within 3 days", .fridge, 180,
         "contested: fresh corn refrigerates per the tip; the name alone files it with dry corn"),
        ("Chickpea", "Canned: pantry 2 years", .pantry, 180, ""),
        ("Salmon", "Refrigerate 2 days, freeze longer", .fridge, 150,
         "refrigerate is primary; freeze is for longer storage"),
        ("Sweet Potato", "Cool dark place, not fridge", .pantry, 120,
         "the tip rules the fridge out; its first storage word wins"),
        ("Ground Beef", "Use within 2 days or freeze", .freezer, 150,
         "ambiguous: the 2-day clock implies the fridge; the tip's only storage word is freeze"),
        ("Lettuce", "Refrigerate, use within 1 week", .fridge, 40, ""),
        ("Apple", "Room temp 1 week, fridge 4-6 weeks", .pantry, 120,
         "contested: room temp first, then fridge; the tip's first storage word wins"),
        ("Peanut Butter", "Room temp, sealed", .pantry, 30, ""),
        ("Frozen Peas", "Keep frozen until use", .freezer, 180, ""),
        ("Canned Tuna", "Pantry 2-5 years", .pantry, 150, ""),
        ("Celery", "Refrigerate in water", .fridge, 120, ""),
        ("Zucchini", "Refrigerate, use within 5 days", .fridge, 120, ""),
        ("Red Pepper Flakes", "Cool dark place", .pantry, 30,
         "gram is a jar-scale heuristic, not the 2 g teaspoon the unit lists"),
        ("Cumin", "Cool dark place", .pantry, 30,
         "gram is a jar-scale heuristic, not the 2 g teaspoon the unit lists"),
        ("Cilantro", "Refrigerate stems in water", .fridge, 40, ""),
        ("Coconut Milk", "Canned: pantry 2 years", .pantry, 240,
         "the name alone would ride 'milk' into the fridge"),
        ("Sour Cream", "Refrigerate, check date", .fridge, 120, ""),
      ]
    for row in rows {
      let item = ingredient(name: row.name, storageTip: row.tip)
      XCTAssertEqual(
        InventoryIntakeService.inferLocation(for: item), row.location,
        "\(row.name): \(row.note)")
      XCTAssertEqual(
        InventoryIntakeService.estimateGrams(forName: row.name), row.grams, "\(row.name): \(row.note)")
    }
  }

  // MARK: - Core-50 characterization (name-only fallback)

  /// What the name alone implies when the tip is missing or unrecognized.
  /// Potato and sweet potato are pinned to pantry because the bundled tips
  /// themselves call for a cool dark place, not the fridge.
  func testCoreFiftyNameOnlyFallback() throws {
    // (name, expected location)
    let rows: [(name: String, location: InventoryStorageLocation)] = [
      ("Egg", .fridge),
      ("Rice", .pantry),
      ("Soy Sauce", .pantry),
      ("Chicken Breast", .fridge),
      ("Onion", .pantry),
      ("Garlic", .pantry),
      ("Tomato", .fridge),
      ("Bell Pepper", .fridge),
      ("Pasta", .pantry),
      ("Potato", .pantry),
      ("Carrot", .fridge),
      ("Cheese", .fridge),
      ("Milk", .fridge),
      ("Butter", .fridge),
      ("Bread", .pantry),
      ("Olive Oil", .pantry),
      ("Lemon", .fridge),
      ("Mushroom", .fridge),
      ("Spinach", .fridge),
      ("Banana", .fridge),
      ("Green Onion", .fridge),
      ("Sesame Oil", .pantry),
      ("Tofu", .fridge),
      ("Broccoli", .fridge),
      ("Cucumber", .fridge),
      ("Avocado", .fridge),
      ("Black Beans", .pantry),
      ("Tortilla", .pantry),
      ("Lime", .fridge),
      ("Ginger", .pantry),
      ("Oats", .pantry),
      ("Yogurt", .fridge),
      ("Honey", .pantry),
      ("Corn", .pantry),
      ("Chickpea", .pantry),
      ("Salmon", .fridge),
      ("Sweet Potato", .pantry),
      ("Ground Beef", .fridge),
      ("Lettuce", .fridge),
      ("Apple", .fridge),
      ("Peanut Butter", .pantry),
      ("Frozen Peas", .freezer),
      ("Canned Tuna", .pantry),
      ("Celery", .fridge),
      ("Zucchini", .fridge),
      ("Red Pepper Flakes", .pantry),
      ("Cumin", .pantry),
      ("Cilantro", .fridge),
      ("Coconut Milk", .pantry),
      ("Sour Cream", .fridge),
    ]
    for row in rows {
      XCTAssertEqual(
        InventoryIntakeService.inferLocation(forName: row.name), row.location, row.name)
    }
  }

  // MARK: - Fixture

  private func ingredient(name: String, storageTip: String?) -> Ingredient {
    Ingredient(
      id: nil, name: name, calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sugar: 0,
      sodium: 0, typicalUnit: nil, storageTip: storageTip, pairsWith: nil, notes: nil,
      description: nil, categoryLabel: nil, spriteGroup: nil, spriteKey: nil)
  }
}
