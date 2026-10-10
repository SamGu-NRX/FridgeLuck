import XCTest
import GRDB
@testable import AppSources

// Policy unit tests on tiny hand cases, then the full replay over all
// 300 committed histories x 4 arms, with cross-checks:
//   - current arm (real LearningService) must match the hand-computed
//     reference decisions in data/expected_current.json exactly
//   - restart agreement (service recreated from DB) on every seed/arm
//   - database-reopen agreement on every seed/arm
// Results are written to $REPLAY_OUT (default: ../data/replay-out) for
// score.py. Full replay takes a couple of minutes; set REPLAY_FAST=1 to run
// only one seed per family for quick smoke builds (results then carry a
// "partial" flag and must not be scored).

final class ReplayTests: XCTestCase {
  private var toolDir: URL {
    // .../scan-correction-eval/SwiftReplay/Tests/ReplayTests/ReplayTests.swift
    let url = URL(fileURLWithPath: #filePath)
    return url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  private var dataDir: URL { toolDir.appendingPathComponent("data") }

  private var outputDir: URL {
    if let custom = ProcessInfo.processInfo.environment["REPLAY_OUT"] {
      return URL(fileURLWithPath: custom)
    }
    return dataDir.appendingPathComponent("replay-out")
  }

  private func loadHistories() throws -> HistoriesFile {
    let data = try Data(contentsOf: dataDir.appendingPathComponent("histories.json"))
    let file = try JSONDecoder().decode(HistoriesFile.self, from: data)
    XCTAssertEqual(file.schema, 1)
    XCTAssertEqual(file.histories.count, 300)
    return file
  }

  private func loadExpected() throws -> ExpectedFile {
    let data = try Data(contentsOf: dataDir.appendingPathComponent("expected_current.json"))
    return try JSONDecoder().decode(ExpectedFile.self, from: data)
  }

  private func makeQueue(_ name: String) throws -> DatabaseQueue {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scan-correction-eval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    var ids: [Int64] = []
    for base in [10, 11, 12, 13, 14] {
      ids.append(contentsOf: [Int64(base), Int64(base + 5), Int64(base + 10), Int64(base + 20)])
    }
    return try ReplayDatabase.make(path: dir.appendingPathComponent(name).path, productIds: ids)
  }

  // MARK: - Policy units

  func testCurrentMatchesReferenceSemantics() throws {
    let queue = try makeQueue("units-current.sqlite")
    let service = try CurrentPolicy(queue: queue)
    // products 10 and 15 exist in the replay schema; nonexistent ids are
    // rejected by the production FK / existence join.
    try service.recordCorrection(label: " Tomato ", product: 10)
    XCTAssertNil(try service.autoCorrect(for: "TOMATO"))  // threshold
    try service.recordCorrection(label: "tomato", product: 10)
    XCTAssertEqual(try service.autoCorrect(for: " tomato "), 10)  // normalized key
    try service.recordCorrection(label: "tomato", product: 15)
    // counts 2-1 -> auto still 10
    XCTAssertEqual(try service.autoCorrect(for: "tomato"), 10)
    try service.restart()
    XCTAssertEqual(try service.autoCorrect(for: "TOMATO"), 10)  // cache reload
  }

  func testRecencyWindowAgesOutStaleChoice() throws {
    let queue = try makeQueue("units-window.sqlite")
    let policy = try RecencyWindowPolicy(queue: queue)
    try policy.recordCorrection(label: "x", product: 10)
    try policy.recordCorrection(label: "x", product: 10)
    XCTAssertEqual(try policy.autoCorrect(for: "x"), 10)
    // six newer corrections to product 15 push product 10 out of the window
    for _ in 0..<6 { try policy.recordCorrection(label: "x", product: 15) }
    XCTAssertEqual(try policy.autoCorrect(for: "x"), 15)
  }

  func testConflictAbstainRequiresMarginAndRecovers() throws {
    let queue = try makeQueue("units-abstain.sqlite")
    let policy = try ConflictAbstainPolicy(queue: queue)
    try policy.recordCorrection(label: "x", product: 10)
    try policy.recordCorrection(label: "x", product: 10)
    XCTAssertEqual(try policy.autoCorrect(for: "x"), 10)  // margin 2 over nothing
    try policy.recordCorrection(label: "x", product: 15)  // conflict: decrement
    XCTAssertNil(try policy.autoCorrect(for: "x"))  // ambiguous -> abstain
    for _ in 0..<3 { try policy.recordCorrection(label: "x", product: 15) }
    XCTAssertEqual(try policy.autoCorrect(for: "x"), 15)  // margin re-established
  }

  // MARK: - Full replay

  func testFullReplayAllFamiliesAllArms() throws {
    let historiesFile = try loadHistories()
    let expected = try loadExpected()
    let fast = ProcessInfo.processInfo.environment["REPLAY_FAST"] == "1"

    var histories = historiesFile.histories
    if fast {
      var selected: [History] = []
      for family in historiesFile.families.map(\.name) {
        selected.append(contentsOf: histories.filter { $0.family == family && $0.seed == 0 })
      }
      histories = selected
    }

    let outDir = outputDir
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let workDir = outDir.appendingPathComponent("tmp-dbs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    let output = try ReplayRunner.runAll(
      histories: histories,
      arms: PolicyFactory.allArms,
      directory: workDir)

    // 1. Current arm must match the hand-computed reference exactly.
    var mismatches: [String] = []
    for result in output.results where result.arm == "current" {
      let key = "\(result.family)/\(result.seed)"
      guard let expectedScans = expected.seeds[key] else {
        mismatches.append("\(key): missing from expected_current.json")
        continue
      }
      let expectedDecisions = expectedScans.map(\.decision)
      let got = result.decisions.map(\.decision)
      if expectedDecisions != got {
        mismatches.append("\(key): expected \(expectedDecisions) got \(got)")
      }
    }
    XCTAssertEqual(mismatches.isEmpty, true, "real LearningService diverged from hand-computed reference:\n" + mismatches.prefix(5).joined(separator: "\n"))

    // 2. Restart and database-reopen agreement everywhere.
    let restartFailures = output.results.filter { !$0.restartAgreement }
    XCTAssertEqual(restartFailures.count, 0, "restart agreement failures: \(restartFailures.map { "\($0.arm)/\($0.family)/\($0.seed)" }.prefix(5))")
    let reopenFailures = output.results.filter { !$0.dbReopenAgreement }
    XCTAssertEqual(reopenFailures.count, 0, "db reopen agreement failures: \(reopenFailures.map { "\($0.arm)/\($0.family)/\($0.seed)" }.prefix(5))")

    // 3. Sanity: no_learning never auto-corrects, never commits a wrong one.
    for result in output.results where result.arm == "no_learning" {
      XCTAssertEqual(result.wrongAuto, 0)
      XCTAssertEqual(result.correctAuto, 0)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(output)
    let outFile = outDir.appendingPathComponent(fast ? "replay-results-partial.json" : "replay-results.json")
    try payload.write(to: outFile)
    print("replay results written to \(outFile.path) (\(output.results.count) seed-results)")
  }
}
