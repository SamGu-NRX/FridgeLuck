import XCTest
import FLDomain
@testable import FLCommunityCore

/// The frozen cross-language fixture contract for FLCommunityCore (see
/// `Fixtures/README.md`), mirroring FridgeLuckCore's pattern.
///
/// Each fixture file is the canonical encoding of one community value:
/// sorted keys, pretty-printed, UTC millisecond timestamps. The test decodes
/// every file, re-encodes it, and demands byte equality both with the file
/// and with a freshly constructed value.
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
        // Tests/FLCommunityCoreTests/<this file> → package root → Fixtures/.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FLCommunityCoreTests
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
        try FLCommunitySchema.validate(manifest.schema)
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

    // MARK: Sample values

    private func sampleSharedCook() throws -> SharedCook {
        let revision = try TestSupport.revision(license: TestSupport.license())
        let cook = try TestSupport.cook(
            id: "cook-fix-1",
            key: revision.key,
            completedAt: try TestSupport.date("2026-10-11T18:42:19.000Z"),
            substitutions: [try TestSupport.substitution(from: "paprika", to: "cayenne", necessity: .preferred)],
            note: "kids loved it"
        )
        return try SharedCook(cook: cook, revision: revision, completedOn: "2026-10-11")
    }

    private func sampleChallengeProgress() throws -> ChallengeProgress {
        let definition = try ChallengeDefinition(
            id: "challenge-october",
            title: "October cook-more",
            goal: ChallengeGoal(kind: .cookDistinctRecipes, targetCount: 2),
            requiredIngredientNames: ["paneer"],
            startsAt: try TestSupport.date("2026-10-01T00:00:00.000Z"),
            endsAt: try TestSupport.date("2026-10-31T23:59:59.000Z")
        )
        let revisionA = try TestSupport.revision(slug: "paneer-tikka", license: TestSupport.license())
        let revisionB = try TestSupport.revision(slug: "shakshuka", revisionNumber: 1, license: TestSupport.license(), ingredients: ["paneer", "eggs", "onion"])
        let enrollment = try ChallengeEnrollment(challengeID: definition.id, joinedAt: try TestSupport.date("2026-10-01T12:00:00.000Z"))
        let cooks = [
            try TestSupport.cook(id: "cook-1", key: revisionA.key, completedAt: try TestSupport.date("2026-10-03T10:00:00.000Z")),
            try TestSupport.cook(id: "cook-2", key: revisionA.key, completedAt: try TestSupport.date("2026-10-04T10:00:00.000Z")),
            try TestSupport.cook(id: "cook-3", key: revisionB.key, completedAt: try TestSupport.date("2026-10-05T10:00:00.000Z")),
        ]
        return try ChallengeEvaluator.progress(
            definition: definition,
            enrollment: enrollment,
            cooks: cooks,
            revisionFor: { key in [revisionA, revisionB].first { $0.key == key } }
        )
    }

    private func sampleProfileEditEvent() throws -> PreferenceEvent {
        let sentence = try TestSupport.profileSentence()
        return try TestSupport.profileEvent(
            "pe-002", sentence: sentence, verdict: .corrected,
            at: "2026-10-04T10:00:00.000Z",
            supersedes: try TestSupport.correction("pe-001", .corrects)
        )
    }

    // MARK: Fixture cases

    private func assertFixture<T: Codable & Equatable>(
        _ file: String, fresh: () throws -> T, as type: T.Type
    ) throws {
        let url = fixturesDirectory.appendingPathComponent(file)
        let freshValue = try fresh()
        if Self.updateMode {
            try FLJSON.canonicalData(freshValue).write(to: url)
            return
        }
        let data = try Data(contentsOf: url)
        let decoded = try FLJSON.canonicalDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, freshValue, "\(file) no longer decodes to the frozen value")
        XCTAssertEqual(try FLJSON.canonicalData(decoded), data, "\(file) is not the canonical encoding of its value")
    }

    func testSharedCookFixture() throws {
        try assertFixture("shared-cook.json", fresh: { try self.sampleSharedCook() }, as: SharedCook.self)
    }

    func testChallengeProgressFixture() throws {
        try assertFixture("challenge-progress.json", fresh: { try self.sampleChallengeProgress() }, as: ChallengeProgress.self)
    }

    func testProfileEditEventFixture() throws {
        try assertFixture("profile-edit-event.json", fresh: { try self.sampleProfileEditEvent() }, as: PreferenceEvent.self)
    }
}
