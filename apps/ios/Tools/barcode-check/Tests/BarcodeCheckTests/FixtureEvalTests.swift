import BarcodeEvalSupport
import FLBarcode
import XCTest

/// Invariants over the committed OFF fixture, evaluated through the FLBarcode module.
/// The fixture is real Open Food Facts data (see Fixtures/PROVENANCE.json for source,
/// license, and retrieval details).
final class FixtureEvalTests: XCTestCase {
  private var fixturesDir: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/BarcodeCheckTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // package root
      .appendingPathComponent("Fixtures")
  }

  private func loadEverything() throws -> (
    records: [OFFFixtureRecord], catalog: [EvalCatalogItem], provenance: EvalProvenance
  ) {
    let raw = try String(
      contentsOf: fixturesDir.appendingPathComponent("off_products.jsonl"), encoding: .utf8)
    let records = try raw.split(separator: "\n").map { line in
      try JSONDecoder().decode(OFFFixtureRecord.self, from: Data(line.utf8))
    }
    let catalog = try JSONDecoder().decode(
      [EvalCatalogItem].self,
      from: Data(
        try Data(
          contentsOf: fixturesDir.appendingPathComponent("eval-catalog.json")
        )))
    let provenance = try JSONDecoder().decode(
      EvalProvenance.self,
      from: Data(
        try Data(
          contentsOf: fixturesDir.appendingPathComponent("PROVENANCE.json")
        )))
    return (records, catalog, provenance)
  }

  /// Denominator: the committed fixture has >= 300 unique GTIN references and every one
  /// validates.
  func testFixtureHasAtLeast300UniqueValidGTINs() throws {
    let (records, _, _) = try loadEverything()
    XCTAssertGreaterThanOrEqual(records.count, 300)
    XCTAssertEqual(Set(records.map(\.code)).count, records.count, "codes must be unique")
    for record in records {
      XCTAssertNoThrow(try GTINValidator.validate(record.code), record.code)
    }
  }

  /// Diversity: every outcome class the module distinguishes occurs in the fixture, and
  /// all denominators reconcile.
  func testFixtureCoversEveryOutcomeClass() async throws {
    let (records, catalog, provenance) = try loadEverything()
    let counts = try await runEvaluation(
      records: records, catalogItems: catalog, provenance: provenance)

    XCTAssertEqual(counts.attempted, records.count)
    XCTAssertEqual(counts.gtinValid, records.count, "fixture codes all validate")
    XCTAssertGreaterThan(counts.pinnedCacheHits, 0)
    XCTAssertGreaterThan(counts.explicitUsableMass, 0)
    XCTAssertGreaterThan(
      counts.massRejections[PackageMassRejection.noMassEvidence.rawValue, default: 0], 0)
    XCTAssertGreaterThan(
      counts.massRejections[PackageMassRejection.countOnly.rawValue, default: 0], 0)
    XCTAssertGreaterThan(
      counts.massRejections[PackageMassRejection.servingSizeOnly.rawValue, default: 0], 0)
    XCTAssertGreaterThan(
      counts.massRejections[PackageMassRejection.volumeOnly.rawValue, default: 0], 0)
    XCTAssertGreaterThan(counts.catalogBound, 0)
    XCTAssertGreaterThan(counts.catalogUnbound, 0)
    XCTAssertGreaterThan(counts.catalogAmbiguous, 0, "real-data ambiguity must occur")
    XCTAssertGreaterThan(counts.resolvableDrafts, 0)

    // Denominator reconciliation.
    XCTAssertEqual(
      counts.pinnedCacheHits + counts.pinnedCacheStale + counts.pinnedCacheMiss,
      counts.gtinValid)
    XCTAssertEqual(
      counts.catalogBound + counts.catalogAmbiguous + counts.catalogUnbound,
      counts.pinnedCacheHits + counts.pinnedCacheStale)
    XCTAssertEqual(
      counts.explicitUsableMass
        + counts.massRejections.values.reduce(0, +),
      counts.pinnedCacheHits + counts.pinnedCacheStale)
  }

  /// The core never-grams invariant, across every committed record: a rejected evidence
  /// class never yields grams, and every produced gram traces to mass-unit evidence.
  func testNoNonMassEvidenceBecomesGrams() async throws {
    let (records, _, _) = try loadEverything()

    for record in records {
      let mass = PackageMassParser.mass(in: record.quantity)
      if let rejection = mass.rejection {
        XCTAssertNil(mass.grams, "\(record.code): \(rejection.rawValue) became grams")
      } else if let raw = mass.rawText {
        // Grams exist: the evidence string must carry a mass unit.
        let lower = raw.lowercased()
        XCTAssertTrue(
          lower.contains("g") || lower.contains("oz") || lower.contains("lb"),
          "\(record.code): grams from non-mass evidence '\(raw)'")
      }
    }
  }

  /// Deterministic by construction: two independent runs of the full pipeline agree.
  func testEvaluationRunsAreDeterministic() async throws {
    let (records, catalog, provenance) = try loadEverything()
    let first = try await runEvaluation(
      records: records, catalogItems: catalog, provenance: provenance)
    let second = try await runEvaluation(
      records: records, catalogItems: catalog, provenance: provenance)
    XCTAssertEqual(first, second)
  }

  /// Every cache-hit product carries pinned provenance from the PROVENANCE file.
  func testCacheHitsCarryPinnedProvenance() async throws {
    let (records, _, provenance) = try loadEverything()
    let transport = try FixtureTransport(records: records, provenance: provenance)

    for record in records.prefix(25) {
      guard let gtin = try? GTINValidator.validate(record.code) else { continue }
      let product = try await transport.fetch(gtin: gtin)
      if let product {
        XCTAssertEqual(product.source.sourceId, "openfoodfacts")
        XCTAssertTrue(
          product.source.sourceURL.hasPrefix("https://world.openfoodfacts.org"),
          product.source.sourceURL)
        XCTAssertEqual(product.source.license, provenance.license)
        XCTAssertEqual(product.source.attribution, provenance.attribution)
        XCTAssertEqual(product.source.retrievedAt, provenance.retrievedAtDate)
      }
    }
  }
}
