import XCTest
import Foundation
import FLDomain
@testable import FLFlowCore

/// The frozen cross-language fixture contract for FLFlowCore's decision
/// types, mirroring FLDomain's `FixtureContractTests`: each fixture file is
/// the canonical encoding of one flow value — sorted keys, pretty-printed,
/// UTC millisecond timestamps — under a `fldomain.v1` schema envelope.
///
/// Regenerate after an intentional contract change:
///
///     FL_UPDATE_FIXTURES=1 swift test --filter FlowFixtureContractTests
///
/// and commit the diff. Regeneration is a contract change; the reviewer of
/// that commit is signing off on every byte.
final class FlowFixtureContractTests: XCTestCase {
    private static let updateMode =
        ProcessInfo.processInfo.environment["FL_UPDATE_FIXTURES"] == "1"

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FLFlowCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    // MARK: Manifest

    private struct ManifestEntry: Codable {
        let file: String
        let kind: String
    }

    private struct Manifest: Codable {
        let schema: String
        let fixtures: [ManifestEntry]
    }

    private var manifest: Manifest {
        Manifest(
            schema: "fldomain.v1",
            fixtures: [
                ManifestEntry(file: "tonight-proposal.json", kind: "TonightProposal"),
                ManifestEntry(file: "tonight-proposal-sparse.json", kind: "TonightProposal"),
                ManifestEntry(file: "resume-card.json", kind: "ResumeCard"),
            ]
        )
    }

    func testManifestSchemaIsValid() throws {
        try FLSchema.validate(manifest.schema)
    }

    /// Every fixture file in Fixtures/ is listed in the manifest, and every
    /// listed file exists — the manifest cannot drift from the directory.
    func testManifestCoversDirectoryExactly() throws {
        let listed = Set(manifest.fixtures.map(\.file))
        let onDisk = Set(
            try FileManager.default.contentsOfDirectory(atPath: fixturesDirectory.path)
                .filter { $0.hasSuffix(".json") && $0 != "manifest.json" }
        )
        XCTAssertEqual(listed, onDisk, "manifest and Fixtures/ disagree")
    }

    // MARK: Fixture cases

    private struct FixtureCase {
        let file: String
        let kind: String
        /// A fresh instance of the flow value, rebuilt from code.
        let fresh: () throws -> any Encodable & Equatable
        /// Decode canonical bytes back into the concrete type.
        let decode: (Data) throws -> Void
    }

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeCases() -> [FixtureCase] {
        [
            FixtureCase(
                file: "tonight-proposal.json",
                kind: "TonightProposal",
                fresh: { try Self.makeNormalProposal(t0: self.t0) },
                decode: { data in _ = try FLJSON.canonicalDecoder().decode(TonightProposal.self, from: data) }
            ),
            FixtureCase(
                file: "tonight-proposal-sparse.json",
                kind: "TonightProposal",
                fresh: { try Self.makeSparseProposal(t0: self.t0) },
                decode: { data in _ = try FLJSON.canonicalDecoder().decode(TonightProposal.self, from: data) }
            ),
            FixtureCase(
                file: "resume-card.json",
                kind: "ResumeCard",
                fresh: {
                    try ResumeCard(sessionID: "sess-1", recipeTitle: "Test galette", stepIndex: 1, stepCount: 2, dueTimerLabels: ["bake"])
                },
                decode: { data in _ = try FLJSON.canonicalDecoder().decode(ResumeCard.self, from: data) }
            ),
        ]
    }

    private static func makeNormalProposal(t0: Date) throws -> TonightProposal {
        // One ready option (with an accepted swap) and one nearly-ready
        // option with a missing line — the two fit shapes side by side.
        let readyFit = try FitLine(requiredCount: 2, sufficientCount: 1, swapCount: 1, checkNames: [])
        let ready = try DinnerOption(
            recipeRevision: TestBuilders.recipeKey("galette"),
            title: "Test galette",
            fit: readyFit,
            reasons: ["all 2 required lines are in stock", "with 1 accepted swap"],
            missing: [],
            assumedStaples: ["black pepper"]
        )
        let partialFit = try FitLine(requiredCount: 3, sufficientCount: 1, swapCount: nil, checkNames: ["feta", "eggs"])
        let partial = try DinnerOption(
            recipeRevision: TestBuilders.recipeKey("soup"),
            title: "Test soup",
            fit: partialFit,
            reasons: ["2 of 3 required lines are in stock"],
            missing: [
                try MissingLine(canonicalName: "eggs", kind: .unknownQuantity),
                try MissingLine(canonicalName: "feta", kind: .short, grams: 50),
            ],
            assumedStaples: []
        )
        return try TonightProposal(
            state: .normal,
            generatedAt: t0,
            servings: 2,
            eaterCount: 2,
            options: [ready, partial]
        )
    }

    private static func makeSparseProposal(t0: Date) throws -> TonightProposal {
        let fit = try FitLine(requiredCount: 1, sufficientCount: 0, swapCount: nil, checkNames: ["rice"])
        let option = try DinnerOption(
            recipeRevision: TestBuilders.recipeKey("fried-rice"),
            title: "Test fried rice",
            fit: fit,
            reasons: ["1 of 1 required lines are in stock"],
            missing: [try MissingLine(canonicalName: "rice", kind: .short, grams: 100)],
            assumedStaples: []
        )
        return try TonightProposal(
            state: .sparseKitchen,
            generatedAt: t0,
            servings: 2,
            eaterCount: 2,
            options: [option],
            shoppingList: [try ShoppingItem(canonicalName: "rice", grams: 100, reason: "short 100 g for the fried rice")]
        )
    }

    // MARK: Byte-stable round trip

    func testFixturesRoundTripByteStable() throws {
        try FileManager.default.createDirectory(at: fixturesDirectory, withIntermediateDirectories: true)
        for fixture in makeCases() {
            let url = fixturesDirectory.appendingPathComponent(fixture.file)
            let freshData = try FLJSON.canonicalData(try fixture.fresh())

            if Self.updateMode {
                try freshData.write(to: url)
                continue
            }

            let frozen = try Data(contentsOf: url)
            // The Swift encoder produces exactly the frozen bytes.
            XCTAssertEqual(freshData, frozen, "\(fixture.file): fresh encoding drifted from the frozen fixture")
            // The frozen bytes decode back into the value they froze.
            try fixture.decode(frozen)
        }
    }

    /// Regenerates every fixture deterministically; the manifest is written
    /// last so a crash mid-write never leaves a manifest listing a missing
    /// file.
    func testManifestIsCanonicalAndWrittenLastInUpdateMode() throws {
        guard Self.updateMode else {
            let data = try Data(contentsOf: fixturesDirectory.appendingPathComponent("manifest.json"))
            let canonical = try FLJSON.canonicalData(manifest)
            XCTAssertEqual(data, canonical, "manifest.json must stay canonical (sorted keys, pretty-printed)")
            return
        }
        for fixture in makeCases() {
            try FLJSON.canonicalData(try fixture.fresh())
                .write(to: fixturesDirectory.appendingPathComponent(fixture.file))
        }
        try FLJSON.canonicalData(manifest)
            .write(to: fixturesDirectory.appendingPathComponent("manifest.json"))
    }

    /// The FLTimestamp gate: a numeric reference-epoch instant is rejected,
    /// never reinterpreted (contract change of the 2026-10-11 foundation
    /// review).
    func testNumericTimestampsAreRejectedOnDecode() throws {
        let numeric = """
        {
          "state" : "normal",
          "generatedAt" : 1760000000.0,
          "servings" : 2,
          "eaterCount" : 2,
          "options" : [ ]
        }
        """
        XCTAssertThrowsError(try FLJSON.canonicalDecoder().decode(TonightProposal.self, from: Data(numeric.utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("generatedAt") || String(describing: error).contains("typeMismatch"), "unexpected error: \(error)")
        }
    }
}
