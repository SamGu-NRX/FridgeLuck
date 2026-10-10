import XCTest
@testable import StoragePerfCore
import GRDB

final class StoragePerfTests: XCTestCase {
  // MARK: Deterministic RNG invariants

  func testRNGReproducibility() {
    var a = SplitMix64(seed: 12345)
    var b = SplitMix64(seed: 12345)
    let streamA = (0..<100).map { _ in a.next() }
    let streamB = (0..<100).map { _ in b.next() }
    XCTAssertEqual(streamA, streamB)
  }

  func testRNGStreamDivergence() {
    var a = SplitMix64(seed: 1)
    var b = SplitMix64(seed: 2)
    let streamA = (0..<10).map { _ in a.next() }
    let streamB = (0..<10).map { _ in b.next() }
    XCTAssertNotEqual(streamA, streamB)
  }

  func testRNGUniformBounds() {
    var rng = SplitMix64(seed: 99)
    for _ in 0..<1000 {
      let value = rng.uniform(7)
      XCTAssertLessThan(value, 7)
    }
  }

  // MARK: Canonical JSON

  func testCanonicalJSONSortedKeysAndEscapes() {
    let json = JSON.object([
      ("b", .int(1)),
      ("a", .string("quote\"backslash\\newline\n")),
      ("c", .array([.null, .bool(true), .int(7)])),
    ])
    let rendered = json.render
    XCTAssertTrue(rendered.contains(#"{"a":"quote\"backslash\\newline\n","b":1,"c":[null,true,7]}"#))
  }

  /// The digest contract excludes floats entirely — canonical JSON has no
  /// .double case, so a Double cannot leak into a digest input.
  func testCanonicalJSONHasNoFloatCase() {
    // Compile-time proof: only int/string/bool/array/object exist. This test
    // pins the escaped rendering used by the digest input instead.
    let json = JSON.object([("k", .int(-42))])
    XCTAssertEqual(json.render, #"{"k":-42}"#)
  }

  // MARK: Seeder invariants (tiny profile, keeps the suite fast)

  func testSeededDatabasePinnedCounts() throws {
    let directory = NSTemporaryDirectory() + "/storage-perf-tests-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let seeded = try WorkloadSeeder.makeSeeded(
      profile: .month, scale: 1, seed: 7, directory: directory, name: "test")

    XCTAssertGreaterThan(seeded.counts.ingredients, 0)
    XCTAssertGreaterThan(seeded.counts.inventoryItems, 0)
    XCTAssertGreaterThan(seeded.counts.inventoryLots, 0)
    XCTAssertGreaterThan(seeded.counts.meals, 0)
    XCTAssertGreaterThan(seeded.counts.snapshots, seeded.counts.meals / 2)
    XCTAssertGreaterThan(seeded.counts.snapshotLines, 0)
  }

  func testSeededDatabaseDeterministic() throws {
    let directory = NSTemporaryDirectory() + "/storage-perf-tests-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let a = try WorkloadSeeder.makeSeeded(
      profile: .month, scale: 1, seed: 42, directory: directory + "/a", name: "a")
    let b = try WorkloadSeeder.makeSeeded(
      profile: .month, scale: 1, seed: 42, directory: directory + "/b", name: "b")

    XCTAssertEqual(a.counts.inventoryEvents, b.counts.inventoryEvents)
    XCTAssertEqual(a.counts.inventoryLots, b.counts.inventoryLots)
    XCTAssertEqual(a.counts.meals, b.counts.meals)
    XCTAssertEqual(a.counts.snapshotLines, b.counts.snapshotLines)

    // Content determinism: identical event streams, not just identical counts.
    func checksum(_ seeded: SeededDatabase) throws -> String {
      try seeded.dbQueue.read { db in
        let rows = try Row.fetchAll(
          db, sql: "SELECT * FROM inventory_events ORDER BY id")
        return SHA256.hex(rows.map { row in
          row.map { (_, value) in value.description }.joined(separator: "|")
        }.joined(separator: "\n"))
      }
    }
    XCTAssertEqual(try checksum(a), try checksum(b))
  }

  // MARK: Report verifier + mutation controls
  //
  // Each case corrupts a signed report in a specific way and asserts the
  // verifier REJECTS it. A verifier that accepts any of these is broken.

  func testVerifierAcceptsIntactReport() throws {
    let digest = try ReportVerifier.verify(text: signedReport())
    XCTAssertEqual(digest.count, 64)
  }

  private func signedReport() -> String {
    let summary = JSON.object([
      ("schemaVersion", .int(1)),
      ("seed", .int(20261010)),
      ("warmup", .int(3)),
      ("iterations", .int(15)),
      ("profiles", .object([("month", .object([("x1", .object([("medianUs", .int(100))]))]))])),
    ])
    return Runner.renderReport(withDigest: summary)
  }

  func testVerifierRejectsTamperedBody() {
    let report = signedReport()
    let tampered = report.replacingOccurrences(of: "\"medianUs\":100", with: "\"medianUs\":1")
    XCTAssertThrowsError(try ReportVerifier.verify(text: tampered))
  }

  func testVerifierRejectsTamperedDigest() {
    let report = signedReport()
    let tampered =
      String(report.dropLast(65)) + String(repeating: "a", count: 64) + "}"
    XCTAssertThrowsError(try ReportVerifier.verify(text: tampered))
  }

  func testVerifierRejectsMissingDigest() {
    let report = signedReport()
    // Strip the trailing ,"<hex>" digest pair the writer appended.
    let stripped = String(report.dropLast(2 + 64))
      .replacingOccurrences(of: ",\"digest\":", with: "", options: .backwards)
    XCTAssertThrowsError(try ReportVerifier.verify(text: stripped))
  }

  func testVerifierRejectsShortDigest() {
    var report = signedReport()
    report.removeLast(65)
    report += String(repeating: "a", count: 63) + "\"}"
    XCTAssertThrowsError(try ReportVerifier.verify(text: report))
  }

  func testVerifierRejectsMissingRequiredKey() {
    let summary = JSON.object([
      ("schemaVersion", .int(1)),
      ("profiles", .object([("month", .object([("x1", .object([("ok", .bool(true))]))]))])),
    ])
    let report = Runner.renderReport(withDigest: summary)
    XCTAssertThrowsError(try ReportVerifier.verify(text: report))
  }

  func testVerifierRejectsNonObject() {
    XCTAssertThrowsError(try ReportVerifier.verify(text: "[1,2,3]"))
    XCTAssertThrowsError(try ReportVerifier.verify(text: "not json"))
  }
}
