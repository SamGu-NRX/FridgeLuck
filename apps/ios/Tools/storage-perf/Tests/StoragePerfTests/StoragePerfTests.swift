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

  /// A minimal but contract-complete v2 report: every read carries its own
  /// warmup/iterations counts, the frozen samples, and a summary that
  /// recomputes from them, plus a synthetic source manifest.
  private func signedReport() -> String {
    let samples: [Int64] = [10, 20, 30, 40]
    let read = JSON.object([
      ("warmup", .int(2)),
      ("iterations", .int(4)),
      ("warmupUs", .array([.int(11), .int(12)])),
      ("iterationsUs", .array(samples.map { .int($0) })),
      ("summary", Metrics.distribution(samples)),
    ])
    let manifestEntries: [JSON] = [
      .object([
        ("path", JSON.string("Package.swift")),
        ("sha256", JSON.string(String(repeating: "0", count: 64))),
      ]),
      .object([
        ("path", JSON.string("Sources/StoragePerfCore/Metrics.swift")),
        ("sha256", JSON.string(String(repeating: "1", count: 64))),
      ]),
    ]
    let manifest = JSON.object([
      ("files", JSON.array(manifestEntries)),
      ("fileCount", JSON.int(2)),
    ])
    let summary = JSON.object([
      ("schemaVersion", .int(1)),
      ("toolVersion", .int(2)),
      ("seed", .int(20261010)),
      ("warmup", .int(3)),
      ("iterations", .int(15)),
      ("sourceManifest", manifest),
      (
        "profiles", .object([
          (
            "month", .object([
              (
                "x1", .object([
                  ("reads", .object([("inventory_use_soon", read)])),
                ])
              )
            ])
          )
        ])
      ),
    ])
    return Runner.renderReport(withDigest: summary)
  }

  func testVerifierRejectsTamperedBody() {
    let report = signedReport()
    let tampered = report.replacingOccurrences(of: "\"p50\":30", with: "\"p50\":1")
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

  // MARK: Summary regeneration (checksum-only verification is insufficient)

  /// A hand-edited summary that is re-signed must still be refused: the
  /// verifier regenerates the summary from the frozen samples.
  func testVerifierRejectsReSignedDoctoredSummary() {
    // Build the same report but with a summary that does not match the
    // samples; the digest is computed over the doctored body, so a
    // checksum-only verifier would accept it.
    let report = signedReport()
    let marker = ",\"digest\":\""
    guard let markerRange = report.range(of: marker, options: .backwards) else {
      return XCTFail("no digest marker")
    }
    let body = String(report[..<markerRange.lowerBound]) + "}"
    // Doctor the p50 inside the signed body, then re-sign.
    guard let p50Range = body.range(of: #""p50":30"#) else {
      return XCTFail("p50 not found in body")
    }
    let doctoredBody = body.replacingCharacters(in: p50Range, with: "\"p50\":9999")
    let doctored = String(doctoredBody.dropLast()) + ",\"digest\":\""
      + SHA256.hex(doctoredBody) + "\"}"
    XCTAssertThrowsError(try ReportVerifier.verify(text: doctored))
  }

  func testVerifierRejectsIterationsCountMismatch() {
    // Record 4 iterations but freeze only 3 samples.
    let report = signedReport()
    let marker = ",\"digest\":\""
    guard let markerRange = report.range(of: marker, options: .backwards) else {
      return XCTFail("no digest marker")
    }
    let body = String(report[..<markerRange.lowerBound]) + "}"
    guard let sampleRange = body.range(of: #""iterationsUs":[10,20,30,40]"#) else {
      return XCTFail("samples not found in body")
    }
    let doctoredBody = body.replacingCharacters(in: sampleRange, with: "\"iterationsUs\":[10,20,30]")
    let doctored = String(doctoredBody.dropLast()) + ",\"digest\":\""
      + SHA256.hex(doctoredBody) + "\"}"
    XCTAssertThrowsError(try ReportVerifier.verify(text: doctored))
  }

  func testVerifierRejectsMissingSourceManifest() {
    let report = signedReport()
    let marker = ",\"digest\":\""
    guard let markerRange = report.range(of: marker, options: .backwards) else {
      return XCTFail("no digest marker")
    }
    let body = String(report[..<markerRange.lowerBound]) + "}"
    guard let manifestRange = body.range(of: #""sourceManifest":{"#) else {
      return XCTFail("manifest not found in body")
    }
    // Drop exactly the manifest pair (render order: ... seed, sourceManifest,
    // toolVersion ...), then re-sign.
    guard let toolVersionRange = body.range(of: #""toolVersion":"#, options: .backwards) else {
      return XCTFail("toolVersion not found in body")
    }
    let without = body.replacingCharacters(
      in: manifestRange.lowerBound..<toolVersionRange.lowerBound, with: "")
    let resigned = String(without.dropLast()) + ",\"digest\":\""
      + SHA256.hex(without) + "\"}"
    XCTAssertThrowsError(try ReportVerifier.verify(text: resigned))
  }

  // MARK: Source manifest binding

  private func makeFakePackageRoot() -> String {
    let root = NSTemporaryDirectory() + "/storage-perf-manifest-\(UUID().uuidString)"
    let fm = FileManager.default
    try? fm.createDirectory(
      atPath: root + "/Sources/StoragePerfCore", withIntermediateDirectories: true)
    try? "// package".write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
    try? "// source".write(
      toFile: root + "/Sources/StoragePerfCore/Metrics.swift", atomically: true,
      encoding: .utf8)
    return root
  }

  func testSourceManifestBuildsVerifiesAndCatchesDrift() throws {
    let root = makeFakePackageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let manifest = try SourceManifest.build(root: root)

    // A report carrying this manifest verifies against the matching root...
    let report = signedReportWithManifest(manifest)
    XCTAssertNoThrow(try ReportVerifier.verify(text: report, sourceRoot: root))

    // ...and drift in ANY recorded file is refused.
    try "// tampered".write(
      toFile: root + "/Sources/StoragePerfCore/Metrics.swift", atomically: true,
      encoding: .utf8)
    XCTAssertThrowsError(try ReportVerifier.verify(text: report, sourceRoot: root))

    // A newly added unrecorded source is also drift.
    try "// extra".write(
      toFile: root + "/Sources/StoragePerfCore/Extra.swift", atomically: true,
      encoding: .utf8)
    try "// original".write(
      toFile: root + "/Sources/StoragePerfCore/Metrics.swift", atomically: true,
      encoding: .utf8)
    XCTAssertThrowsError(try ReportVerifier.verify(text: report, sourceRoot: root))
  }

  /// signedReport with the real source manifest swapped in (hashes correct
  /// for the synthetic root).
  private func signedReportWithManifest(_ manifest: JSON) -> String {
    // Re-render the synthetic report with the provided manifest by swapping
    // the pair inside the object and re-signing.
    let report = signedReport()
    let marker = ",\"digest\":\""
    guard let markerRange = report.range(of: marker, options: .backwards) else {
      fatalError("no digest marker")
    }
    var body = String(report[..<markerRange.lowerBound]) + "}"
    // Replace the two synthetic manifest entries with the real ones via JSON
    // manipulation on the string level is brittle; instead rebuild the body
    // through the canonical writer.
    let parsed = try! JSON.parse(body)
    guard case .object(let pairs) = parsed else { fatalError("not an object") }
    let swapped = pairs.map { key, value in
      key == "sourceManifest" ? ("sourceManifest", manifest) : (key, value)
    }
    let rebuilt = JSON.object(swapped)
    body = CanonicalJSON.digestInput(rebuilt)
    return String(body.dropLast()) + ",\"digest\":\"" + SHA256.hex(body) + "\"}"
  }

  // MARK: JSON parser

  func testJSONParserRoundTrip() throws {
    let value = JSON.object([
      ("a", .array([.int(1), .int(-22), .null, .bool(false)])),
      ("b", .string("esc\"ape\\slash\n")),
      ("c", .object([("z", .int(3)), ("a", .int(4))])),
    ])
    let parsed = try JSON.parse(value.render)
    XCTAssertEqual(parsed.render, value.render)
  }

  func testJSONParserRejectsFloats() {
    XCTAssertThrowsError(try JSON.parse(#"{"a":1.5}"#))
    XCTAssertThrowsError(try JSON.parse(#"{"a":1e3}"#))
  }

  // MARK: Linux /proc memory parsing (tab-separated)

  private let procStatusFixture = """
    Name:\tstorage-perf
    VmPeak:\t 2048000 kB
    VmRSS:\t  94208 kB
    RssAnon:\t 40960 kB
    VmHWM:\t  98304 kB
    Threads:\t4
    """

  /// Linux separates /proc/self/status keys from values with a TAB; the
  /// original parser split on spaces only, silently reporting 0 for every
  /// row. Tab-separated content must parse.
  func testMemoryStatusParsesTabSeparatedProcOutput() {
    let reading = Metrics.parseMemoryStatus(procStatusFixture)
    XCTAssertTrue(reading.available)
    XCTAssertEqual(reading.vmRssKB, 94208)
    XCTAssertEqual(reading.vmHwmKB, 98304)
  }

  func testMemoryStatusParsesSpaceSeparatedFallback() {
    let reading = Metrics.parseMemoryStatus("VmRSS: 512 kB\nVmHWM: 768 kB\n")
    XCTAssertTrue(reading.available)
    XCTAssertEqual(reading.vmRssKB, 512)
    XCTAssertEqual(reading.vmHwmKB, 768)
  }

  /// Zero or missing fields mean unmeasured — never a measured 0.
  func testMemoryStatusMarksUnavailableInsteadOfZero() {
    for broken in [
      "Name:\tstorage-perf\n",               // fields absent
      "VmRSS:\t0 kB\nVmHWM:\t0 kB\n",          // zeros
      "VmRSS:\tnone kB\nVmHWM:\t0 kB\n",       // unparsable value
      "",                                      // empty file
    ] {
      let reading = Metrics.parseMemoryStatus(broken)
      XCTAssertFalse(reading.available)
      XCTAssertNil(reading.vmRssKB)
      XCTAssertNil(reading.vmHwmKB)
    }
  }
}
