import XCTest
@testable import ProductionReplay

// Bit-exact control-arm parity: the vendored Swift production code, run on the
// frozen matrix, must reproduce the Python reference fixture EXACTLY - same
// rank order, same Int ratings, same labels, same explanation strings, same
// rankingReasons lists, and same raw IEEE-754 bits for every ranking score.

final class ControlParityTests: XCTestCase {
  static let sensitivityRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests/ReplayTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // SwiftReplay
    .deletingLastPathComponent()  // health-ranking-sensitivity

  struct Fixture: Decodable {
    struct ProfileFixture: Decodable {
      struct Recipe: Decodable {
        let id: String
        let rank: Int
        let rating: Int
        let label: String
        let reasoning: String
        let rankingScoreBits: String
        let rankingReasons: [String]
        enum CodingKeys: String, CodingKey {
          case id, rank, rating, label, reasoning
          case rankingScoreBits = "ranking_score_bits"
          case rankingReasons = "ranking_reasons"
        }
      }
      let recipes: [Recipe]
    }
    let matrixSha256: String
    let profiles: [String: ProfileFixture]
    enum CodingKeys: String, CodingKey {
      case profiles
      case matrixSha256 = "matrix_sha256"
    }
  }

  func loadMatrix() throws -> FrozenMatrix {
    try ReplayEngine.loadJSON(
      FrozenMatrix.self,
      path: Self.sensitivityRoot.appendingPathComponent("inputs/frozen_matrix.json").path)
  }

  func testControlArmMatchesPythonFixtureBitExactly() throws {
    let fixture = try JSONDecoder().decode(
      Fixture.self,
      from: Data(
        contentsOf: Self.sensitivityRoot
          .appendingPathComponent("SwiftReplay/Tests/ReplayTests/fixtures/python_control.json")))
    let matrix = try loadMatrix()

    var compared = 0
    for profile in matrix.profiles {
      guard let expected = fixture.profiles[profile.id] else {
        XCTFail("fixture missing profile \(profile.id)")
        continue
      }
      let actual = ReplayEngine.controlRecords(matrix: matrix, profile: profile)
      XCTAssertEqual(actual.count, expected.recipes.count, "\(profile.id): recipe count")
      for (a, e) in zip(actual, expected.recipes) {
        XCTAssertEqual(a.recipeId, e.id, "\(profile.id): rank order diverged")
        XCTAssertEqual(a.rank, e.rank, "\(profile.id)/\(e.id): rank")
        XCTAssertEqual(a.rating, e.rating, "\(profile.id)/\(e.id): rating")
        XCTAssertEqual(a.label, e.label, "\(profile.id)/\(e.id): label")
        XCTAssertEqual(a.reasoning, e.reasoning, "\(profile.id)/\(e.id): reasoning")
        XCTAssertEqual(a.rankingReasons, e.rankingReasons, "\(profile.id)/\(e.id): rankingReasons")
        XCTAssertEqual(
          UInt64(a.rankingScoreBits), UInt64(e.rankingScoreBits),
          "\(profile.id)/\(e.id): rankingScore bits")
        XCTAssertEqual(
          a.rankingScore.bitPattern, UInt64(e.rankingScoreBits)!,
          "\(profile.id)/\(e.id): Double bit pattern")
        compared += 1
      }
    }
    XCTAssertGreaterThanOrEqual(compared, 62 * 5, "expected full matrix control coverage")
  }

  func testControlArmIsInternallyConsistentAcrossRepeatedRuns() throws {
    let matrix = try loadMatrix()
    for profile in matrix.profiles {
      let a = ReplayEngine.controlRecords(matrix: matrix, profile: profile)
      let b = ReplayEngine.controlRecords(matrix: matrix, profile: profile)
      XCTAssertEqual(
        a.map(\.rankingScoreBits), b.map(\.rankingScoreBits),
        "\(profile.id): control must be deterministic")
    }
  }
}
