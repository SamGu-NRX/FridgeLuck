import XCTest
@testable import FLDomain

/// Review round 1, item 6 (SPEC 3.4): the shareable form of a cook carries
/// the day — never exact start or finish times — and never pantry, health or
/// taste data, which are not even representable. The redaction test freezes
/// the coded key set: nothing joins it without a deliberate contract change.
final class CookSharingTests: XCTestCase {
    private let startedAt = try! FLTimestamp.decode("2026-10-11T08:14:23.000Z", target: "test")
    private let completedAt = try! FLTimestamp.decode("2026-10-11T08:52:07.000Z", target: "test")

    private func makeCook() throws -> Cook {
        try Cook(
            id: "cook-share-1",
            recipeRevision: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
            servings: 3,
            substitutions: [try CookSubstitution(
                from: IngredientReference(canonicalName: "onion"),
                to: IngredientReference(canonicalName: "shallot"),
                necessity: .preferred
            )],
            rating: 5,
            note: "weekend hit",
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    func testShareCardCarriesTheDayOnly() throws {
        let card = try CookShareCard(cook: makeCook())
        XCTAssertEqual(card.day, "2026-10-11", "the day, derived in UTC — no time of day")
        XCTAssertEqual(card.servings, 3)
        XCTAssertEqual(card.rating, 5)
        XCTAssertEqual(card.note, "weekend hit")
        XCTAssertEqual(card.swaps.count, 1)
        XCTAssertEqual(card.swaps[0].fromName, "onion")
        XCTAssertEqual(card.swaps[0].toName, "shallot")
        XCTAssertEqual(card.swaps[0].necessity, .preferred)
    }

    func testShareCardEncodingRedactsExactTimes() throws {
        let raw = String(decoding: try FLJSON.canonicalData(try CookShareCard(cook: makeCook())), as: UTF8.self)
        XCTAssertFalse(raw.contains("startedAt"), "no exact start time may be representable")
        XCTAssertFalse(raw.contains("completedAt"), "no exact finish time may be representable")
        XCTAssertFalse(raw.contains("08:14"), "no exact time of day may leak")
        XCTAssertFalse(raw.contains("08:52"), "no exact time of day may leak")
        XCTAssertFalse(raw.contains("cook-share-1"), "the household-local cook ID must not travel")
    }

    func testShareCardKeySetIsFrozen() throws {
        let data = try FLJSON.canonicalData(try CookShareCard(cook: makeCook()))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let keys = Set((object as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(
            keys,
            ["recipeRevision", "day", "servings", "swaps", "rating", "note"],
            "the coded key set is the whole sharing contract (SPEC 3.4): pantry, health and taste data are not representable"
        )
    }

    func testShareCardRejectsMalformedDaysAndOutliers() throws {
        XCTAssertThrowsError(try CookShareCard(
            recipeRevision: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
            servings: 3,
            swaps: [],
            rating: 5,
            note: nil,
            day: "2026-10-11T08:52:07Z"
        ), "a timestamp is not a day")
        XCTAssertThrowsError(try CookShareCard(
            recipeRevision: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
            servings: 0,
            swaps: [],
            rating: 5,
            note: nil,
            day: "2026-10-11"
        ), "servings rules carry over from Cook")
        XCTAssertThrowsError(try CookShareCard(
            recipeRevision: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
            servings: 2,
            swaps: [],
            rating: 9,
            note: nil,
            day: "2026-10-11"
        ), "rating rules carry over from Cook")
    }
}
