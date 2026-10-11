import XCTest
@testable import FLTaste

/// Snapshot serialization: round-trip byte equality, determinism across
/// ingest orders, fail-closed migration boundaries, golden fixture.
final class SerializationTests: XCTestCase {
    func testRoundTripIsByteIdenticalAndStateEqual() throws {
        var engine = Fixtures.engine()
        engine.ingest(Fixtures.scenarioEvents())
        let first = try engine.snapshotJSON()

        let restored = try TasteEngine(snapshotJSON: first, catalog: Fixtures.catalog())
        let second = try restored.snapshotJSON()

        XCTAssertEqual(first, second, "round-trip must produce byte-identical snapshots")
        XCTAssertEqual(restored.state, engine.state)
        XCTAssertEqual(restored.config, engine.config)
        XCTAssertEqual(restored.eventCount, engine.eventCount)
    }

    func testSameEventsTwiceProduceByteIdenticalState() throws {
        // The task's determinism gate: ingesting the same fixture events
        // twice (two independent engines) yields identical serialized state.
        var a = Fixtures.engine()
        var b = Fixtures.engine()
        a.ingest(Fixtures.scenarioEvents())
        b.ingest(Fixtures.scenarioEvents())
        XCTAssertEqual(try a.snapshotJSON(), try b.snapshotJSON())
    }

    func testUnknownFormatVersionFailsClosed() throws {
        var engine = Fixtures.engine()
        engine.ingest(Fixtures.scenarioEvents())
        let snapshot = try engine.snapshotJSON()
        let mutated = snapshot
            .replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":99")
        XCTAssertThrowsError(try TasteEngine(snapshotJSON: mutated, catalog: Fixtures.catalog()))
    }

    func testUnknownConfigVersionFailsClosed() throws {
        var engine = Fixtures.engine()
        engine.ingest(Fixtures.scenarioEvents())
        let snapshot = try engine.snapshotJSON()
        let mutated = snapshot
            .replacingOccurrences(of: "\"configVersion\":1", with: "\"configVersion\":42")
        XCTAssertThrowsError(try TasteEngine(snapshotJSON: mutated, catalog: Fixtures.catalog()))
    }

    func testUnknownEventKindFailsClosed() {
        let hostile = """
        {"config":{"configVersion":1},"events":[{"at":1767225600000,"eater":null,"exposure":null,\
        "id":"e1","kind":{"telepathy":{"recipe":"r_rice_bowl"}}}],\
        "featureSpaceVersion":"taste-features-v1","formatVersion":1}
        """
        XCTAssertThrowsError(try TasteEngine(snapshotJSON: hostile, catalog: Fixtures.catalog()))
    }

    func testGoldenFixture() throws {
        // Committed canonical bytes for the scenario. Regenerate deliberately
        // (FLTASTE_REGENERATE_GOLDEN=1 swift test --filter testGoldenFixture)
        // and review the diff; the test fails when they drift.
        var engine = Fixtures.engine()
        engine.ingest(Fixtures.scenarioEvents())
        let golden = try engine.snapshotJSON()

        // The source-tree location, resolved from this file so a
        // regeneration lands where a commit can pick it up.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden-v1.json")

        if ProcessInfo.processInfo.environment["FLTASTE_REGENERATE_GOLDEN"] == "1" {
            try golden.write(to: sourceURL, atomically: true, encoding: .utf8)
            XCTFail("golden fixture regenerated at \(sourceURL.path); review and commit the diff")
            return
        }

        let committed = try String(contentsOf: goldenFixtureURL(), encoding: .utf8)
        XCTAssertEqual(golden, committed)
    }

    private func goldenFixtureURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["FLTASTE_GOLDEN_PATH"] {
            return URL(fileURLWithPath: override)
        }
        // Prefer the committed source copy; fall back to the test-bundle
        // resource when running from a checkout where it has not been
        // generated yet.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden-v1.json")
        if FileManager.default.fileExists(atPath: source.path) { return source }
        return URL(fileURLWithPath: Bundle.module.bundlePath)
            .appendingPathComponent("Fixtures/golden-v1.json")
    }
}
