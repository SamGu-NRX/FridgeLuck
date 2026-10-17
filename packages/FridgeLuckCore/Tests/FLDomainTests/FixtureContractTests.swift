import XCTest
@testable import FLDomain

/// The frozen cross-language fixture contract (see `Fixtures/README.md`).
///
/// Each fixture file is the canonical encoding of one domain value: sorted
/// keys, pretty-printed, UTC millisecond timestamps. The test decodes every
/// file, re-encodes it, and demands byte equality both with the file and with
/// a freshly constructed value — proving the Swift encoder produces exactly
/// the frozen bytes and the decoder accepts them back.
///
/// Regenerate the frozen files after an intentional contract change:
///
///     FL_UPDATE_FIXTURES=1 swift test --filter FixtureContractTests
///
/// and commit the diff. Regeneration is a contract change; the reviewer of
/// that commit is signing off on every byte.
final class FixtureContractTests: XCTestCase {
    private static let updateMode =
        ProcessInfo.processInfo.environment["FL_UPDATE_FIXTURES"] == "1"

    private var fixturesDirectory: URL {
        // Tests/FLDomainTests/<this file> → package root → Fixtures/.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FLDomainTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    // MARK: Manifest

    private struct ManifestEntry: Decodable {
        let file: String
        let kind: String
    }

    private struct Manifest: Decodable {
        let schema: String
        let fixtures: [ManifestEntry]
    }

    private func loadManifest() throws -> (Manifest, Data) {
        let url = fixturesDirectory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        let manifest = try FLJSON.canonicalDecoder().decode(Manifest.self, from: data)
        return (manifest, data)
    }

    func testManifestSchemaIsValid() throws {
        let (manifest, _) = try loadManifest()
        try FLSchema.validate(manifest.schema)
    }

    /// Every fixture file in Fixtures/ is listed in the manifest, and every
    /// listed file exists — the manifest cannot drift from the directory.
    func testManifestCoversDirectoryExactly() throws {
        let (manifest, _) = try loadManifest()
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
        /// A fresh instance of the domain value, rebuilt from code.
        let fresh: () throws -> any Encodable & Equatable
        /// Decode `data` back and assert it equals `fresh`.
        let decode: (Data) throws -> Void
    }

    private static func timestamp(_ raw: String) throws -> Date {
        try FLTimestamp.decode(raw, target: "fixture")
    }

    private static func sampleCook() throws -> Cook {
        try Cook(
            id: "cook-fix-1",
            recipeRevision: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
            servings: 2,
            substitutions: [
                try CookSubstitution(
                    from: IngredientReference(canonicalName: "onion"),
                    to: IngredientReference(canonicalName: "shallot"),
                    necessity: .necessary
                )
            ],
            rating: 4,
            note: "kids loved it",
            startedAt: try timestamp("2026-10-11T12:00:00.000Z"),
            completedAt: try timestamp("2026-10-11T12:30:00.000Z")
        )
    }

    private static func sampleEvent() throws -> PreferenceEvent {
        try PreferenceEvent(
            id: "event-fix-1", kind: .cookCompleted,
            timestamp: try timestamp("2026-10-11T12:30:00.000Z"),
            recipeRevision: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
            source: .userExplicit,
            supersedes: EventCorrection(priorEventID: PreferenceEventID("event-fix-0"), mode: .corrects),
            rating: 2,
            wouldRepeat: false,
            note: "was too salty"
        )
    }

    private static func sampleProposal() throws -> ActionProposal {
        try ActionProposal(
            id: "proposal-fix-1", tool: .proposeStepAdvance,
            payload: .stepAdvance(stepIndex: 2),
            payloadHash: "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
            snapshotRevision: 3,
            createdAt: try timestamp("2026-10-11T12:00:00.000Z"),
            expiresAt: try timestamp("2026-10-11T12:45:00.000Z")
        )
    }

    private static func sampleReceipt() throws -> ActionReceipt {
        try ActionReceipt(
            proposalID: "proposal-fix-1", state: .executed,
            payloadHash: "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
            snapshotRevision: 3,
            recordedAt: try timestamp("2026-10-11T12:30:00.000Z")
        )
    }

    private static func sampleNutritionValues() throws -> NutritionValues {
        try NutritionValues(
            caloriesKcal: 350, proteinGrams: 12, carbohydrateGrams: 40, fatGrams: 9,
            saturatedFatGrams: 2, fiberGrams: 3, sugarGrams: 6, sodiumGrams: 0.5
        )
    }

    private static func sampleRecipeRevision() throws -> RecipeRevision {
        try RecipeRevision(
            key: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
            title: "Saturday Pancakes",
            servingBasis: ServingBasis(servings: 4),
            ingredientLines: [
                IngredientLine(
                    lineID: "line-1",
                    ingredient: IngredientReference(canonicalName: "all-purpose flour"),
                    quantity: .sourceGrams(GramMass(grams: 250))
                ),
                IngredientLine(
                    lineID: "line-2",
                    ingredient: IngredientReference(canonicalName: "whole milk"),
                    quantity: .householdMeasure(
                        HouseholdMeasure(
                            amount: 1, unit: "cup", gramsPerUnit: 244,
                            conversionSource: "USDA FNDDS: 1 cup whole milk = 244 g"
                        )
                    )
                ),
                IngredientLine(
                    lineID: "line-3",
                    ingredient: IngredientReference(canonicalName: "maple syrup"),
                    quantity: .unknown,
                    isOptionalGarnish: true
                ),
            ],
            steps: [
                Step(
                    stepID: "step-1", action: "Whisk the batter",
                    durationSeconds: 180, equipment: ["large bowl"]
                ),
                Step(
                    stepID: "step-2", action: "Cook until bubbles form and edges set",
                    temperature: CookingTemperature(celsius: 71, purpose: .internalDoneness),
                    equipment: ["nonstick skillet"],
                    safetyCheck: SafetyCheck(
                        instruction: "cook until the internal temperature reaches the egg-safe level",
                        minimumInternalCelsius: 71,
                        source: "USDA FSIS Safe Minimum Internal Temperature Chart"
                    )
                ),
            ],
            source: RecipeSourceEvidence(
                origin: .user,
                attribution: nil,
                license: RecipeLicense(
                    textRedistribution: .permitted, imageRedistribution: .permitted,
                    modificationAllowed: .permitted, attributionRequired: false,
                    cachingAllowed: .permitted, offlineUseAllowed: .permitted,
                    evidence: "author declaration recorded at import"
                )
            )
        )
    }

    private func cases() throws -> [FixtureCase] {
        [
            FixtureCase(
                file: "cook.json", kind: "Cook",
                fresh: { try Self.sampleCook() },
                decode: { data in
                    let decoded = try FLJSON.canonicalDecoder().decode(Cook.self, from: data)
                    XCTAssertEqual(try FLJSON.canonicalData(decoded), try FLJSON.canonicalData(Self.sampleCook()))
                }
            ),
            FixtureCase(
                file: "preference-event.json", kind: "PreferenceEvent",
                fresh: { try Self.sampleEvent() },
                decode: { data in
                    let decoded = try FLJSON.canonicalDecoder().decode(PreferenceEvent.self, from: data)
                    XCTAssertEqual(try FLJSON.canonicalData(decoded), try FLJSON.canonicalData(Self.sampleEvent()))
                }
            ),
            FixtureCase(
                file: "action-proposal.json", kind: "ActionProposal",
                fresh: { try Self.sampleProposal() },
                decode: { data in
                    let decoded = try FLJSON.canonicalDecoder().decode(ActionProposal.self, from: data)
                    XCTAssertEqual(try FLJSON.canonicalData(decoded), try FLJSON.canonicalData(Self.sampleProposal()))
                }
            ),
            FixtureCase(
                file: "action-receipt.json", kind: "ActionReceipt",
                fresh: { try Self.sampleReceipt() },
                decode: { data in
                    let decoded = try FLJSON.canonicalDecoder().decode(ActionReceipt.self, from: data)
                    XCTAssertEqual(try FLJSON.canonicalData(decoded), try FLJSON.canonicalData(Self.sampleReceipt()))
                }
            ),
            FixtureCase(
                file: "nutrition-values.json", kind: "NutritionValues",
                fresh: { try Self.sampleNutritionValues() },
                decode: { data in
                    let decoded = try FLJSON.canonicalDecoder().decode(NutritionValues.self, from: data)
                    XCTAssertEqual(try FLJSON.canonicalData(decoded), try FLJSON.canonicalData(Self.sampleNutritionValues()))
                }
            ),
            FixtureCase(
                file: "recipe-revision.json", kind: "RecipeRevision",
                fresh: { try Self.sampleRecipeRevision() },
                decode: { data in
                    let decoded = try FLJSON.canonicalDecoder().decode(RecipeRevision.self, from: data)
                    XCTAssertEqual(try FLJSON.canonicalData(decoded), try FLJSON.canonicalData(Self.sampleRecipeRevision()))
                }
            ),
        ]
    }

    // MARK: The contract test

    func testFixturesAreCanonicalAndRoundTrip() throws {
        let manifest = try loadManifest().0
        try FLSchema.validate(manifest.schema)
        let listedKinds = Dictionary(uniqueKeysWithValues: manifest.fixtures.map { ($0.file, $0.kind) })

        for fixtureCase in try cases() {
            let url = fixturesDirectory.appendingPathComponent(fixtureCase.file)
            let canonicalBytes = try FLJSON.canonicalData(try fixtureCase.fresh())

            if Self.updateMode {
                try canonicalBytes.write(to: url)
                continue
            }

            let fileBytes = try Data(contentsOf: url)
            // The file is exactly what the canonical encoder produces.
            XCTAssertEqual(
                fileBytes, canonicalBytes,
                "\(fixtureCase.file) is not the canonical encoding of \(fixtureCase.kind); regenerate with FL_UPDATE_FIXTURES=1"
            )
            // The decoder accepts those bytes back with no loss.
            try fixtureCase.decode(fileBytes)
            // The manifest names the same kind the test exercises.
            XCTAssertEqual(try XCTUnwrap(listedKinds[fixtureCase.file]), fixtureCase.kind)
        }
    }

    /// In update mode the run must not silently pass without writing — an
    /// empty update is a mistake.
    func testUpdateModeWritesAllCases() throws {
        guard Self.updateMode else { return }
        for fixtureCase in try cases() {
            let url = fixturesDirectory.appendingPathComponent(fixtureCase.file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "update mode did not write \(fixtureCase.file)")
        }
    }
}

/// `#filePath` on Linux sometimes lands inside the build directory; FilePath
/// normalizes it. Small shim so the fixture directory resolves on macOS too.
private import Foundation
