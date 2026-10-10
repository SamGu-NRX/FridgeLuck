import FLBarcode
import XCTest
@testable import FridgeLuck

/// App-side wiring for barcode intake. These tests compile and run under the hosted iOS
/// test suite (FridgeLuckTests); the Linux barcode-check package covers the FLBarcode
/// coordinator behaviors with fakes.
final class BarcodeIntakeWiringTests: XCTestCase {
  // MARK: - Commit mapping

  func testIngestItemMapsMeasuredProvenanceAndScanSource() throws {
    let item = BarcodeCommitItem(
      ingredientId: 42, quantityGrams: 454, isMeasured: true, confidence: 0.9)

    let mapped = IntakeServiceBarcodeCommitter.ingestItem(from: item, ingredient: nil)

    XCTAssertEqual(mapped.ingredientId, 42)
    XCTAssertEqual(mapped.quantityGrams, 454)
    XCTAssertEqual(mapped.quantityProvenance, .measured, "package mass must commit as measured")
    XCTAssertEqual(mapped.source, .scan)
    XCTAssertEqual(mapped.confidenceScore, 0.9)
    XCTAssertEqual(mapped.storageLocation, .unknown, "no ingredient means no location guess")
  }

  func testIngestItemMapsEnteredProvenanceForUserAmount() throws {
    let item = BarcodeCommitItem(
      ingredientId: 7, quantityGrams: 250, isMeasured: false, confidence: 1.0)

    let mapped = IntakeServiceBarcodeCommitter.ingestItem(from: item, ingredient: nil)

    XCTAssertEqual(mapped.quantityProvenance, .entered, "user-set amounts commit as entered")
  }

  func testIngestItemInfersLocationFromIngredientTip() throws {
    var ingredient = Ingredient(
      id: 5, name: "Greek yogurt", calories: 59, protein: 10, carbs: 3.6, fat: 0.4,
      fiber: 0, sugar: 3.2, sodium: 36, typicalUnit: nil, storageTip: "Keep refrigerated.",
      pairsWith: nil, notes: nil, description: nil, categoryLabel: nil, spriteGroup: nil,
      spriteKey: nil)
    let item = BarcodeCommitItem(
      ingredientId: 5, quantityGrams: 170, isMeasured: true, confidence: 0.9)

    let mapped = IntakeServiceBarcodeCommitter.ingestItem(from: item, ingredient: ingredient)
    XCTAssertEqual(mapped.storageLocation, .fridge)

    ingredient.storageTip = "Store in the freezer."
    let frozen = IntakeServiceBarcodeCommitter.ingestItem(from: item, ingredient: ingredient)
    XCTAssertEqual(frozen.storageLocation, .freezer)
  }

  // MARK: - Catalog resolver

  private func ingredient(_ id: Int64, _ name: String) -> Ingredient {
    Ingredient(
      id: id, name: name, calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sugar: 0,
      sodium: 0, typicalUnit: nil, storageTip: nil, pairsWith: nil, notes: nil,
      description: nil, categoryLabel: nil, spriteGroup: nil, spriteKey: nil)
  }

  func testResolverProbesLongestTokensAndRanksBestFirst() {
    var probes: [String] = []
    let resolver = IngredientCatalogBarcodeResolver(search: { query in
      probes.append(query)
      if query.contains("yogurt") {
        return [self.ingredient(11, "Greek yogurt"), self.ingredient(12, "Yogurt")]
      }
      return []
    })

    let candidates = resolver.candidates(for: "Greek yogurt", brands: "Fage")

    XCTAssertTrue(probes.contains("yogurt"), "the resolver must probe on product tokens")
    XCTAssertGreaterThanOrEqual(candidates.count, 2)
    XCTAssertEqual(candidates.first?.id, 11, "better token overlap ranks first")
    for pair in zip(candidates, candidates.dropFirst()) {
      XCTAssertTrue(pair.0.score >= pair.1.score, "candidates are ordered score-descending")
    }
  }

  func testResolverReturnsNoCandidatesForEmptyQuery() {
    let resolver = IngredientCatalogBarcodeResolver(search: { _ in
      XCTFail("empty query must not search")
      return []
    })
    XCTAssertTrue(resolver.candidates(for: nil, brands: nil).isEmpty)
    XCTAssertTrue(resolver.candidates(for: "", brands: "x").isEmpty)
  }

  func testResolverNearTieStaysAmbiguousThroughTheBinder() {
    let resolver = IngredientCatalogBarcodeResolver(search: { _ in
      // Two candidates whose names both contain every query token — a near tie.
      [self.ingredient(21, "Almond butter"), self.ingredient(22, "Almond butter spread")]
    })

    let binding = CatalogBinder.bind(
      resolver.candidates(for: "Almond butter", brands: nil))

    guard case .ambiguous(let candidates) = binding else {
      return XCTFail("a near tie must stay ambiguous, got \(binding)")
    }
    XCTAssertEqual(candidates.count, 2)
  }

  func testResolverStrongLeaderBinds() {
    let resolver = IngredientCatalogBarcodeResolver(search: { _ in
      // The runner-up misses the "butter" token entirely — a clear leader.
      [self.ingredient(31, "Almond butter"), self.ingredient(32, "Almond")]
    })

    let binding = CatalogBinder.bind(
      resolver.candidates(for: "Almond butter", brands: nil))

    guard case .bound(let id, let name, _) = binding else {
      return XCTFail("a clear leader must bind, got \(binding)")
    }
    XCTAssertEqual(id, 31)
    XCTAssertEqual(name, "Almond butter")
  }
}
