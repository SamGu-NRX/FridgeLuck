import XCTest
@testable import FLDomain

/// The cross-language JSON contract: canonical encoders emit sorted keys and
/// millisecond UTC timestamps, decoders accept the shapes Swift, TypeScript and
/// Python produce, and every fixture-covered type round trips equal.
final class JSONRoundTripTests: XCTestCase {
    private let revision = try! RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1)

    // MARK: Timestamps

    func testTimestampEncodeEmitsMillisecondsUTC() throws {
        let t = try FLTimestamp.decode("2026-10-11T12:00:00.123Z", target: "test")
        XCTAssertEqual(FLTimestamp.encode(t), "2026-10-11T12:00:00.123Z")
    }

    func testTimestampDecodeAcceptsSecondsWithoutFraction() throws {
        // TS/Python producers may omit fractional seconds; decoding accepts it.
        let t = try FLTimestamp.decode("2026-10-11T12:00:00Z", target: "test")
        XCTAssertEqual(FLTimestamp.encode(t), "2026-10-11T12:00:00.000Z")
    }

    func testTimestampRejectsNonInstances() {
        XCTAssertThrowsError(try FLTimestamp.decode("yesterday", target: "test"))
        XCTAssertThrowsError(try FLTimestamp.decode("", target: "test"))
    }

    // MARK: Canonical encoder

    /// Canonical JSON is byte-stable: encoding twice gives the same bytes, so a
    /// fixture round trip in another language can be compared exactly.
    func testCanonicalEncoderIsDeterministicAndSorted() throws {
        let values = try NutritionValues(caloriesKcal: 350, proteinGrams: 12, fatGrams: 9)
        let first = try FLJSON.canonicalData(values)
        let second = try FLJSON.canonicalData(values)
        XCTAssertEqual(first, second)

        // Keys arrive in sorted order regardless of declaration order.
        let text = String(data: first, encoding: .utf8)!
        let calories = text.range(of: #""caloriesKcal""#)!.lowerBound
        let fat = text.range(of: #""fatGrams""#)!.lowerBound
        let protein = text.range(of: #""proteinGrams""#)!.lowerBound
        XCTAssertLessThan(calories, fat)
        XCTAssertLessThan(fat, protein)
    }

    // MARK: Full-type round trips

    func testQuantityEvidenceRoundTrip() throws {
        let decoder = FLJSON.canonicalDecoder()
        let weighed = QuantityEvidence.weighedGrams(try GramMass(grams: 120))
        let decoded = try decoder.decode(QuantityEvidence.self, from: FLJSON.canonicalData(weighed))
        XCTAssertEqual(decoded, weighed)
        // The tagged shape: kind names the variant, the payload is a nested object.
        let text = String(data: try FLJSON.canonicalData(weighed), encoding: .utf8)!
        XCTAssertTrue(text.contains(#""kind" : "weighedGrams""#))
        XCTAssertTrue(text.contains(#""grams""#))
    }

    func testNutritionReportRoundTrip() throws {
        let values = try NutritionValues(
            caloriesKcal: 350, proteinGrams: 12, carbohydrateGrams: 40, fatGrams: 9,
            saturatedFatGrams: 2, fiberGrams: 3, sugarGrams: 6, sodiumGrams: 0.5
        )
        let report = try NutritionReport(values: values, coverage: .complete)
        let decoded = try FLJSON.canonicalDecoder().decode(NutritionReport.self, from: FLJSON.canonicalData(report))
        XCTAssertEqual(decoded, report)
    }

    func testAssistantContractRoundTrips() throws {
        let checkpoint = try CookingSessionCheckpoint(
            sessionID: "s1", recipeRevision: revision, stepIndex: 0,
            completedStepIDs: [], timers: [],
            updatedAt: try FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")
        )
        let decodedCheckpoint = try FLJSON.canonicalDecoder().decode(CookingSessionCheckpoint.self, from: FLJSON.canonicalData(checkpoint))
        XCTAssertEqual(decodedCheckpoint, checkpoint)

        let snapshot = try AssistantContextSnapshot(
            sessionID: "s1", revision: 1,
            capturedAt: try FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test"),
            pantrySummary: []
        )
        let decodedSnapshot = try FLJSON.canonicalDecoder().decode(AssistantContextSnapshot.self, from: FLJSON.canonicalData(snapshot))
        XCTAssertEqual(decodedSnapshot, snapshot)
    }

    // MARK: Fixture schema version

    func testSchemaVersionAcceptsMajorAndMinor() {
        XCTAssertNoThrow(try FLSchema.validate("fldomain.v1"))
        XCTAssertNoThrow(try FLSchema.validate("fldomain.v1.2"))
        XCTAssertThrowsError(try FLSchema.validate("fldomain.v2"))
        XCTAssertThrowsError(try FLSchema.validate("fldomain"))
        XCTAssertThrowsError(try FLSchema.validate("fldomain.v1.x"))
        XCTAssertThrowsError(try FLSchema.validate("somethingelse.v1"))
    }
}
