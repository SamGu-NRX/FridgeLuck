import CryptoKit
import XCTest

@testable import FridgeLuck

/// Verifies the SHIPPED recipe bundle against the manifest sidecar that ships
/// next to it: the manifest's provenance numbers (counts, hashes, rights labels,
/// legacy links) must describe exactly the bytes the app carries, so a stale
/// sidecar or a drifted bundle fails CI instead of shipping a wrong story.
///
/// Tests run hosted in the app (TEST_HOST), so Bundle.main is the app bundle and
/// both resources are the real files the app reads at launch.
final class RecipeCatalogManifestIntegrityTests: XCTestCase {
  private var bundleData: Data!
  private var bundleRoot: [String: Any]!
  private var manifest: [String: Any]!

  override func setUpWithError() throws {
    try super.setUpWithError()

    guard let url = RecipeBundleV2Loader.bundleV2URL(in: .main) else {
      XCTFail("shipped bundle missing from the app bundle: Resources/RecipeCatalog/recipes-v2.json")
      throw XCTSkip("bundle resource not shipped — the app would fall back to legacy data.json")
    }
    bundleData = try Data(contentsOf: url)

    // The sidecar must sit in the same directory as the bundle, not anywhere else.
    let sidecarURL = url.deletingLastPathComponent().appendingPathComponent("manifest.json")
    guard let sidecarData = try? Data(contentsOf: sidecarURL) else {
      XCTFail("manifest sidecar missing next to the shipped bundle: \(sidecarURL.path)")
      return
    }
    manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(with: sidecarData) as? [String: Any],
      "manifest sidecar is not a JSON object")
    bundleRoot = try XCTUnwrap(
      JSONSerialization.jsonObject(with: bundleData) as? [String: Any],
      "shipped bundle is not a JSON object")
  }

  // MARK: - Provenance

  func testManifestHashMatchesTheShippedBytes() throws {
    let digest = SHA256.hash(data: bundleData)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let recorded = try XCTUnwrap(
      (manifest["bundle"] as? [String: Any])?["sha256"] as? String,
      "manifest records no bundle sha256")
    XCTAssertEqual(hex, recorded, "shipped bundle bytes do not match the manifest hash")
  }

  func testManifestByteCountMatchesTheShippedBytes() throws {
    let recorded = try XCTUnwrap(
      (manifest["bundle"] as? [String: Any])?["bytes"] as? Int,
      "manifest records no bundle byte count")
    XCTAssertEqual(bundleData.count, recorded, "shipped bundle size does not match the manifest")
  }

  // MARK: - Counts

  private func contents() throws -> [String: Any] {
    try XCTUnwrap(manifest["contents"] as? [String: Any], "manifest records no contents")
  }

  private func recipes() throws -> [[String: Any]] {
    try XCTUnwrap(bundleRoot["recipes"] as? [[String: Any]], "bundle carries no recipes array")
  }

  private func ingredients() throws -> [[String: Any]] {
    try XCTUnwrap(
      bundleRoot["ingredients"] as? [[String: Any]],
      "bundle carries no ingredients array")
  }

  func testManifestRecipeCountMatchesTheShippedBundle() throws {
    let shipped = try recipes().count
    XCTAssertEqual(shipped, try contents()["recipes"] as? Int)
  }

  func testManifestIngredientCountMatchesTheShippedBundle() throws {
    let shipped = try ingredients().count
    XCTAssertEqual(shipped, try contents()["ingredients"] as? Int)
  }

  func testManifestRightsStatusCountsMatchTheShippedBundle() throws {
    let rights = try XCTUnwrap(
      contents()["rights_status"] as? [String: Any],
      "manifest records no rights_status")
    var original = 0
    var quarantined = 0
    for recipe in try recipes() {
      let rights = try XCTUnwrap(recipe["rights"] as? [String: Any])
      let status = rights["status"] as? String
      if status == "original" {
        original += 1
      } else if status == "quarantined" {
        quarantined += 1
      } else {
        XCTFail("recipe with no schema-legal rights status (original|quarantined): "
          + "\(String(describing: status))")
      }
    }
    XCTAssertEqual(
      original, rights["original"] as? Int,
      "original count disagrees with the manifest")
    XCTAssertEqual(
      quarantined, rights["quarantined"] as? Int,
      "quarantined count disagrees with the manifest")
  }

  func testManifestNutritionCoverageMatchesTheShippedBundle() throws {
    let coverage = try XCTUnwrap(
      contents()["nutrition_coverage"] as? [String: Any],
      "manifest records no nutrition_coverage")
    var counts: [String: Int] = [:]
    for recipe in try recipes() {
      let name = try XCTUnwrap(
        (recipe["nutrition_per_serving"] as? [String: Any])?["coverage"] as? String,
        "recipe carries no nutrition coverage")
      counts[name, default: 0] += 1
    }
    XCTAssertEqual(counts["computed"], coverage["computed"] as? Int)
    XCTAssertEqual(counts["estimated"], coverage["estimated"] as? Int)
    XCTAssertEqual(counts["partial"], coverage["partial"] as? Int)
  }

  func testManifestLegacyLinkCountMatchesTheShippedBundle() throws {
    let links = try XCTUnwrap(
      contents()["legacy_ingredient_links"] as? [String: Any],
      "manifest records no legacy_ingredient_links")
    var withLegacyID = 0
    var seen = Set<Int>()
    for ingredient in try ingredients() {
      if let id = ingredient["legacy_id"] as? Int {
        withLegacyID += 1
        XCTAssertTrue((1...50).contains(id), "legacy_id \(id) is outside the 50 legacy rows")
        XCTAssertFalse(seen.contains(id), "legacy id \(id) is claimed by two ingredient keys")
        seen.insert(id)
      }
    }
    XCTAssertEqual(
      withLegacyID, links["keys_with_legacy_id"] as? Int,
      "number of keys carrying a legacy_id disagrees with the manifest")
  }

  // MARK: - Per-recipe invariants the rights story rests on

  func testEveryRecipeCarriesRightsEvidenceAndABoundedCatalogID() throws {
    for recipe in try recipes() {
      let catalogID = try XCTUnwrap(recipe["catalog_id"] as? String)
      let rights = try XCTUnwrap(recipe["rights"] as? [String: Any])
      let evidence = rights["evidence"] as? String
      XCTAssertFalse(
        (evidence ?? "").isEmpty,
        "\(catalogID) ships a rights status with no pinned evidence")
    }
  }

  func testEveryRecipeCarriesNonNegativeNutrition() throws {
    for recipe in try recipes() {
      let nutrition = try XCTUnwrap(recipe["nutrition_per_serving"] as? [String: Any])
      let kcal = try XCTUnwrap(nutrition["kcal"] as? Double, "recipe without kcal")
      XCTAssertGreaterThanOrEqual(kcal, 0)
      XCTAssertLessThan(kcal, 4000, "per-serving kcal out of any plausible range")
    }
  }
}
