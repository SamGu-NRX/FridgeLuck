import XCTest
@testable import ProductionReplay

// Vendored-region parity: every region between REPLAY-VENDORED-REGION markers
// in VendoredScoring.swift must be byte-identical to the corresponding region
// of the production source at the pinned base (line ranges pinned in
// RegionManifest.json). Fails on any production drift.

final class VendoredRegionParityTests: XCTestCase {
  static let sensitivityRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests/ReplayTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // SwiftReplay
    .deletingLastPathComponent()  // health-ranking-sensitivity
  static let repoRoot = sensitivityRoot
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // ios
    .deletingLastPathComponent()  // apps
    .deletingLastPathComponent()  // repo root

  struct RegionManifest: Decodable {
    struct Region: Decodable {
      let id: String
      let file: String
      let startLine: Int
      let endLine: Int
      let sha256: String
      enum CodingKeys: String, CodingKey {
        case id, file
        case startLine = "start_line"
        case endLine = "end_line"
        case sha256
      }
    }
    let regions: [Region]
  }

  func lines(_ url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
  }

  func testVendoredRegionsAreByteIdenticalToProduction() throws {
    let manifest = try JSONDecoder().decode(
      RegionManifest.self,
      from: Data(contentsOf: Self.sensitivityRoot.appendingPathComponent("RegionManifest.json")))
    let vendoredURL = Self.sensitivityRoot
      .appendingPathComponent("SwiftReplay/Sources/ProductionReplay/VendoredScoring.swift")
    let vendoredLines = try lines(vendoredURL)

    XCTAssertFalse(manifest.regions.isEmpty, "manifest must list regions")
    for region in manifest.regions {
      let prodURL = Self.repoRoot.appendingPathComponent(region.file)
      let prodLines = try lines(prodURL)
      XCTAssertGreaterThanOrEqual(
        prodLines.count, region.endLine,
        "\(region.id): production file shorter than manifest claims (drift)")
      let prodRegion = prodLines[(region.startLine - 1)..<region.endLine]
        .joined(separator: "\n") + "\n"

      let startMarker = "// REPLAY-VENDORED-REGION-START \(region.id)"
      let endMarker = "// REPLAY-VENDORED-REGION-END \(region.id)"
      guard
        let s = vendoredLines.firstIndex(of: startMarker),
        let e = vendoredLines.firstIndex(of: endMarker),
        s + 1 < e
      else {
        XCTFail("markers missing or inverted for \(region.id)")
        continue
      }
      XCTAssertEqual(
        vendoredLines.filter { $0 == startMarker }.count, 1,
        "\(region.id): start marker must be unique")
      XCTAssertEqual(
        vendoredLines.filter { $0 == endMarker }.count, 1,
        "\(region.id): end marker must be unique")

      let embedded = vendoredLines[(s + 1)..<e].joined(separator: "\n") + "\n"
      XCTAssertEqual(embedded, prodRegion, "\(region.id): vendored region drifted from production")
    }
  }

  func testManifestCoversTheExpectedRegionSet() {
    // Guard against silently dropping a region from the parity claim.
    let expected: Set<String> = [
      "HealthScore_struct", "computeScore_func", "buildReasoning_func",
      "RecipeMacros_struct", "RecipeTags_struct", "Recipe_struct",
      "HealthProfile_struct", "sharedRankingScore_and_rankingReasons",
    ]
    guard
      let manifest = try? JSONDecoder().decode(
        RegionManifest.self,
        from: Data(
          contentsOf: Self.sensitivityRoot.appendingPathComponent("RegionManifest.json")))
    else {
      XCTFail("RegionManifest.json unreadable")
      return
    }
    XCTAssertEqual(Set(manifest.regions.map(\.id)), expected)
  }
}
