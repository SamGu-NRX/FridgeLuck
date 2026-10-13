import XCTest

/// Scaffold boot check only — asserts the harness package itself is intact.
/// Real behavior tests arrive with the Profile Basics core; this file makes
/// no claim about production behavior.
final class HarnessSmokeTests: XCTestCase {
  func testHarnessLayoutExists() {
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: "Sources/ProfileBasicsCheck"),
      "link-sources.sh should create Sources/ProfileBasicsCheck")
  }
}
