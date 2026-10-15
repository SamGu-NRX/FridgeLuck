import Foundation
import XCTest

/// Loads the contract example fixtures copied from `docs/spec/community/contracts/examples/`
/// into `Tests/Community/Fixtures/`. Every example the app uses is decoded in a unit test, so
/// a contract change that breaks the app fails a test the same day it lands (SPEC 8.5).
enum CommunityContractFixtures {
  enum FixtureError: Error {
    case missing(String)
  }

  static func load(_ name: String, file: StaticString = #filePath) throws -> Data {
    // Source-tree-relative first: deterministic on every platform (Linux SPM scatters bundle
    // resources into target-specific bundles, so Bundle lookups are unreliable there).
    let sourceDir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    let relative = sourceDir.appending(path: "Fixtures/\(name).json")
    if FileManager.default.fileExists(atPath: relative.path) {
      return try Data(contentsOf: relative)
    }

    let bundle = Bundle(for: FixtureMarker.self)
    // macOS keeps resources flat; Linux SPM keeps the source subdirectory.
    for subdirectory in [nil, "Fixtures", "CommunityCheckTests/Fixtures"] {
      if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory) {
        return try Data(contentsOf: url)
      }
    }
    throw FixtureError.missing(name)
  }

  /// Anchor type so `Bundle(for:)` resolves the test bundle from any call site.
  private final class FixtureMarker {}
}
