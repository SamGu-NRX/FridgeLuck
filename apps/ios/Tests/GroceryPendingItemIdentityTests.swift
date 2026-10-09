import XCTest

@testable import FridgeLuck

/// Identity correction keeps the amount story honest: a heuristic guess belongs to the old
/// food and is re-derived (or dropped); a value the user set or an explicit weight describes
/// the physical item and survives the swap.
final class GroceryPendingItemIdentityTests: XCTestCase {
  private func makeItem(
    grams: Double?,
    provenance: QuantityProvenance?
  ) -> GroceryPendingItem {
    GroceryPendingItem(
      ingredientId: 3,
      ingredientName: "Eggs",
      quantityGrams: grams,
      storageLocation: .pantry,
      confidenceScore: 0.9,
      source: .scan,
      quantityProvenance: provenance,
      alternatives: [
        GroceryAlternative(id: 7, name: "Milk"),
        GroceryAlternative(id: 9, name: "Yogurt"),
      ]
    )
  }

  func testEstimatesAreReDerivedFromTheNewFood() {
    var item = makeItem(grams: 100, provenance: .estimate)
    item.replaceIdentity(ingredientId: 9, name: "Yogurt", estimatedGrams: 150)
    XCTAssertEqual(item.ingredientId, 9)
    XCTAssertEqual(item.ingredientName, "Yogurt")
    XCTAssertEqual(item.quantityGrams ?? 0, 150, accuracy: 0.05)
    XCTAssertEqual(item.quantityProvenance, .estimate)
  }

  func testEstimatesWithoutAKnownUnitMassBecomeUnknown() {
    var item = makeItem(grams: 100, provenance: .estimate)
    item.replaceIdentity(ingredientId: 9, name: "Yogurt", estimatedGrams: nil)
    XCTAssertNil(item.quantityGrams)
    XCTAssertNil(item.quantityProvenance)
    XCTAssertFalse(item.isResolvedForCommit)
  }

  func testMeasuredAmountsSurviveIdentityCorrection() {
    var item = makeItem(grams: 454, provenance: .measured)
    item.replaceIdentity(ingredientId: 9, name: "Yogurt", estimatedGrams: 150)
    XCTAssertEqual(item.quantityGrams ?? 0, 454, accuracy: 0.05)
    XCTAssertEqual(item.quantityProvenance, .measured)
  }

  func testUserEnteredAmountsSurviveIdentityCorrection() {
    var item = makeItem(grams: 300, provenance: .entered)
    item.replaceIdentity(ingredientId: 9, name: "Yogurt", estimatedGrams: 900)
    XCTAssertEqual(item.quantityGrams ?? 0, 300, accuracy: 0.05)
    XCTAssertEqual(item.quantityProvenance, .entered)
  }

  func testCorrectionRemovesThePickedFoodFromAlternatives() {
    var item = makeItem(grams: 100, provenance: .estimate)
    item.replaceIdentity(ingredientId: 9, name: "Yogurt", estimatedGrams: nil)
    XCTAssertFalse(item.alternatives.contains { $0.id == 9 })
    XCTAssertTrue(item.alternatives.contains { $0.id == 7 })
  }

  func testSettingAnAmountRecordsItsProvenance() {
    var item = makeItem(grams: nil, provenance: nil)
    item.setAmount(200, provenance: .measured)
    XCTAssertEqual(item.quantityGrams ?? 0, 200, accuracy: 0.05)
    XCTAssertEqual(item.quantityProvenance, .measured)
    XCTAssertTrue(item.isResolvedForCommit)
  }
}
