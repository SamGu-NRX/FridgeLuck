import XCTest
import FLDomain
@testable import FLCommunityCore

/// SPEC 3.4: what a shared cook may contain is a fixed shape — recipe
/// revision, servings, swaps, rating, one-line note, calendar day. NEVER
/// pantry, health profile, taste data or exact time beyond the day. These
/// tests freeze that redaction boundary on the wire.
final class SharedCookRedactionTests: XCTestCase {
    private func sharedCook(note: String? = nil, substitutions: [CookSubstitution] = []) throws -> SharedCook {
        let revision = try TestSupport.revision(license: TestSupport.license())
        let cook = try TestSupport.cook(
            id: "cook-1",
            key: revision.key,
            completedAt: try TestSupport.date("2026-10-11T18:42:19.000Z"),
            substitutions: substitutions,
            note: note,
            startedAt: try TestSupport.date("2026-10-11T18:12:00.000Z")
        )
        return try SharedCook(
            cook: cook,
            revision: revision,
            completedOn: SharedCook.dayString(for: try TestSupport.date("2026-10-11T18:42:19.000Z"), timeZone: TimeZone(identifier: "Europe/Berlin")!)
        )
    }

    private func wireKeys(_ shared: SharedCook) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: try FLJSON.canonicalData(shared)) as! [String: Any]
        return object.keys.sorted()
    }

    func testWireShapeCarriesExactlyTheFrozenKeys() throws {
        let shared = try sharedCook(
            note: "kids loved it",
            substitutions: [try TestSubstitution()]
        )
        XCTAssertEqual(try wireKeys(shared), SharedCook.sharedFieldNames)
        XCTAssertEqual(SharedCook.sharedFieldNames, ["completedOn", "note", "rating", "recipeRevision", "servings", "swaps"])
    }

    func testNoNoteOmitsTheKeyEntirely() throws {
        let shared = try sharedCook()
        XCTAssertFalse(try wireKeys(shared).contains("note"))
    }

    func testCompletedOnIsACalendarDayNotAnInstant() throws {
        let shared = try sharedCook()
        XCTAssertEqual(shared.completedOn, "2026-10-11")
        let object = try JSONSerialization.jsonObject(with: try FLJSON.canonicalData(shared)) as! [String: Any]
        // The wire value is a bare "yyyy-MM-dd" string: no time, no zone.
        XCTAssertEqual(object["completedOn"] as? String, "2026-10-11")
    }

    func testStartedAtInstantStaysBehind() throws {
        // The cook had a startedAt; nothing derived from it appears anywhere
        // in the wire bytes.
        let shared = try sharedCook()
        let text = String(data: try FLJSON.canonicalData(shared), encoding: .utf8)!
        XCTAssertFalse(text.contains("startedAt"))
        XCTAssertFalse(text.contains("18:12"))
        XCTAssertFalse(text.contains("18:42"))
        XCTAssertFalse(text.contains("T18"))
    }

    func testMismatchedRevisionKeyRefuses() throws {
        let revision = try TestSupport.revision(license: TestSupport.license())
        let otherKey = try RecipeKey(source: .user, sourceRecipeID: "different-recipe", revision: 1)
        let cook = try TestSupport.cook(id: "cook-1", key: otherKey, completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2026-10-11")) { error in
            guard case let FLDomainError.validation(target, reason) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(target, "SharedCook.recipeRevision")
            XCTAssertTrue(reason.contains("different-recipe"))
        }
    }

    func testImpossibleCalendarDayRefuses() throws {
        let revision = try TestSupport.revision(license: TestSupport.license())
        let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2026-02-30"))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2026-13-01"))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "26-10-11"))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2026-2-3"))
        // 2100 is not a leap year (divisible by 100, not by 400).
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2100-02-29"))
        XCTAssertNoThrow(try SharedCook(cook: cook, revision: revision, completedOn: "2028-02-29"), "2028 is a leap year")
    }

    func testDayStringConvertsAcrossZones() throws {
        let instant = try TestSupport.date("2026-10-11T23:30:00.000Z")
        XCTAssertEqual(
            SharedCook.dayString(for: instant, timeZone: TimeZone(identifier: "Europe/Berlin")!),
            "2026-10-12"
        )
        XCTAssertEqual(
            SharedCook.dayString(for: instant, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!),
            "2026-10-12"
        )
        XCTAssertEqual(
            SharedCook.dayString(for: instant, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!),
            SharedCook.dayString(for: instant, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!)
        )
    }

    func testSwapsRoundTripWithNecessity() throws {
        let shared = try sharedCook(substitutions: [try TestSubstitution()])
        let bytes = try FLJSON.canonicalData(shared)
        let decoded = try FLJSON.canonicalDecoder().decode(SharedCook.self, from: bytes)
        XCTAssertEqual(decoded, shared)
        XCTAssertEqual(decoded.swaps.first?.necessity, .preferred)
        XCTAssertEqual(decoded.swaps.first?.asSubstitution?.from.canonicalName, "paprika")
        XCTAssertEqual(decoded.swaps.first?.asSubstitution?.to.canonicalName, "cayenne")
    }

    func testMultiLineNoteRefuses() throws {
        let object: [String: Any] = [
            "recipeRevision": try JSONSerialization.jsonObject(with: try FLJSON.canonicalData(try TestSupport.revision(license: TestSupport.license()))),
            "servings": 2,
            "rating": 4,
            "note": "line one\nline two",
            "completedOn": "2026-10-11",
        ]
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try FLJSON.canonicalDecoder().decode(SharedCook.self, from: json)) { error in
            guard case let FLDomainError.validation(target, _) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(target, "SharedCook.note")
        }
    }

    func testZeroServingsOnTheWireRefuses() throws {
        let shared = try sharedCook()
        var object = try JSONSerialization.jsonObject(with: try FLJSON.canonicalData(shared)) as! [String: Any]
        object["servings"] = 0
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try FLJSON.canonicalDecoder().decode(SharedCook.self, from: json))
    }

    // MARK: Export policy — the same rights gate as recipe sharing (review round 2)

    /// A shared cook embeds the full revision text, so constructing one is an
    /// export and must pass the same gate as `RecipeSharePayload`: forbidden
    /// or quarantined text must never leave the phone (SPEC 3.5), failing
    /// closed when rights are missing or unknown.
    func testSharedCookRefusesForbiddenTextRevision() throws {
        let revision = try TestSupport.revision(license: TestSupport.license(text: .forbidden))
        let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2026-10-11")) { error in
            guard case let FLDomainError.validation(target, reason) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(target, "SharedCook.recipeRevision")
            XCTAssertTrue(reason.contains("forbidden"), "unexpected reason: \(reason)")
        }
    }

    func testSharedCookRefusesForbiddenOfflineUse() throws {
        let revision = try TestSupport.revision(license: TestSupport.license(offline: .forbidden))
        let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2026-10-11"))
    }

    func testSharedCookRefusesQuarantinedRevision() throws {
        // Unknown rights mean quarantine, and a quarantined revision is
        // "private, not re-shareable, not shippable" — including embedded in
        // a shared cook. Caching must be explicitly permitted (2026-10-11).
        let quarantined: [(String, RecipeLicense)] = [
            ("unknown text rights", try TestSupport.license(text: .unknown)),
            ("unknown modification rights", try TestSupport.license(modification: .unknown)),
            ("unknown offline rights", try TestSupport.license(offline: .unknown)),
            ("unknown caching rights", try TestSupport.license(caching: .unknown)),
            ("forbidden caching rights", try TestSupport.license(caching: .forbidden)),
        ]
        for (label, license) in quarantined {
            let revision = try TestSupport.revision(license: license)
            let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: Date(timeIntervalSince1970: 0))
            XCTAssertThrowsError(
                try SharedCook(cook: cook, revision: revision, completedOn: "2026-10-11"),
                "\(label) must refuse shared-cook export"
            )
        }
    }

    func testSharedCookRefusesLeChefDraft() throws {
        let revision = try TestSupport.revision(origin: .lechef, license: TestSupport.license())
        let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2026-10-11")) { error in
            guard case let FLDomainError.validation(target, reason) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(target, "SharedCook.recipeRevision")
            XCTAssertTrue(reason.contains("LeChef drafts are private"), "unexpected reason: \(reason)")
        }
    }

    func testSharedCookRefusesAttributionRequiredButMissing() throws {
        let revision = try TestSupport.revision(license: TestSupport.license(attributionRequired: true), attribution: nil)
        let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertThrowsError(try SharedCook(cook: cook, revision: revision, completedOn: "2026-10-11")) { error in
            guard case let FLDomainError.validation(target, reason) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(target, "SharedCook.recipeRevision")
            XCTAssertTrue(reason.contains("attribution"), "unexpected reason: \(reason)")
        }
    }

    func testSharedCookAcceptsAttributionRequiredWithAttributionPresent() throws {
        // The gate blocks the missing case, not attribution itself.
        let revision = try TestSupport.revision(license: TestSupport.license(attributionRequired: true), attribution: "Recipe by Ama Boateng")
        let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNoThrow(try SharedCook(cook: cook, revision: revision, completedOn: "2026-10-11"))
    }
}

/// Local helper so the redaction tests read cleanly.
private func TestSubstitution() throws -> CookSubstitution {
    try TestSupport.substitution(from: "paprika", to: "cayenne", necessity: .preferred)
}
