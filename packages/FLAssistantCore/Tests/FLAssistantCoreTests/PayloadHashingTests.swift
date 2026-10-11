import XCTest
@testable import FLAssistantCore
import FLDomain

final class PayloadHashingTests: XCTestCase {
    // Independent vectors, computed with Python's hashlib over the exact
    // canonical bytes (2-space indent, `"key" : value` spacing), not with the
    // code under test. If the hasher or the canonical encoder drifts, these
    // literals fail.
    private static let stepAdvanceCanonicalBytes = Data(
        "{\n  \"kind\" : \"stepAdvance\",\n  \"stepIndex\" : 2\n}".utf8
    )
    private static let stepAdvanceHash = "ac8328c89dc923820c9e382e3de8ddb46d43e5caf307e8979b7e58d2c2791e82"
    private static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func testSHA256OfCanonicalPayloadMatchesIndependentVector() throws {
        let payload = ActionPayload.stepAdvance(stepIndex: 2)
        let canonical = try FLJSON.canonicalData(payload)
        // The bytes are the frozen canonical form the fixtures rely on.
        XCTAssertEqual(canonical, Self.stepAdvanceCanonicalBytes)
        // The hash is SHA-256 over exactly those bytes.
        XCTAssertEqual(FLPayloadHashing.sha256Hex(canonical), Self.stepAdvanceHash)
        XCTAssertEqual(try FLPayloadHashing.payloadHash(payload), Self.stepAdvanceHash)
    }

    func testSHA256OfEmptyDataMatchesKnownVector() {
        XCTAssertEqual(FLPayloadHashing.sha256Hex(Data()), Self.emptyHash)
    }

    func testHashIsAlwaysDecoderCompatible() throws {
        // The hash FLDomain's ActionProposal/ActionApproval decode must be
        // 64 lowercase hex characters — every payload variant's hash qualifies.
        let payloads: [ActionPayload] = [
            .stepAdvance(stepIndex: 0),
            .timerCreate(label: "eggs", seconds: 600),
            .pantryCorrection(canonicalName: "flour", quantity: .unknown),
            .mealLog(cook: try Cook(
                id: "c1",
                recipeRevision: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
                servings: 2,
                rating: 4,
                completedAt: try FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")
            )),
        ]
        for payload in payloads {
            let hash = try FLPayloadHashing.payloadHash(payload)
            XCTAssertEqual(hash.count, 64, "hash length for \(payload)")
            XCTAssertNoThrow(try FLHashFormat.validateSHA256Hex(hash, target: "test"), "hash format for \(payload)")
        }
    }

    func testHashChangesWhenPayloadContentChanges() throws {
        let eggs = try FLPayloadHashing.payloadHash(.timerCreate(label: "eggs", seconds: 600))
        let eggsLonger = try FLPayloadHashing.payloadHash(.timerCreate(label: "eggs", seconds: 601))
        let otherLabel = try FLPayloadHashing.payloadHash(.timerCreate(label: "egg s", seconds: 600))
        XCTAssertNotEqual(eggs, eggsLonger)
        XCTAssertNotEqual(eggs, otherLabel)
    }

    func testHashIsStableForEqualPayloadsAcrossInstances() throws {
        let first = try FLPayloadHashing.payloadHash(.pantryCorrection(canonicalName: "flour", quantity: .unknown))
        let second = try FLPayloadHashing.payloadHash(.pantryCorrection(canonicalName: "flour", quantity: .unknown))
        XCTAssertEqual(first, second)
    }
}
