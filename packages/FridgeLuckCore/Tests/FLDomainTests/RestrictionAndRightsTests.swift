import XCTest
@testable import FLDomain

/// Review round 1, items 3, 5 and the Nutrition.swift part of item 7.
/// Rejection tests written against the unfixed behaviour: on current code the
/// normalization and exact-coverage tests fail (exclusions are stored raw,
/// caching ignores its grant, partial coverage need not name every missing
/// line). The rights tests additionally document the SPEC 3.5 rule.
final class RestrictionAndRightsTests: XCTestCase {
    // MARK: - Item 3: restriction normalization

    func testCustomExclusionsAreStoredNormalized() throws {
        let restriction = try Restriction(customExclusions: ["  Buckwheat  ", "BUCKWHEAT groats"])
        // Trimmed and case-folded at construction; duplicates collapse.
        XCTAssertEqual(restriction.customExclusions, ["buckwheat", "buckwheat groats"])
    }

    func testUntrimmedExclusionBlocksCanonicalName() throws {
        let restriction = try Restriction(customExclusions: [" buckwheat "])
        XCTAssertFalse(restriction.permits(canonicalName: "buckwheat"), "an exclusion stored with padding must still block the canonical name")
        XCTAssertFalse(restriction.permits(canonicalName: "Buckwheat"))
        XCTAssertFalse(restriction.permits(canonicalName: "  buckwheat "))
        XCTAssertTrue(restriction.permits(canonicalName: "buckwheat flour"), "matching is canonical-name equality after normalization, not prefix matching")
    }

    func testDecodedExclusionsAreNormalized() throws {
        let json = Data(#"{"customExclusions":["  Buckwheat  "]}"#.utf8)
        let restriction = try FLJSON.canonicalDecoder().decode(Restriction.self, from: json)
        XCTAssertEqual(restriction.customExclusions, ["buckwheat"])
    }

    func testWhitespaceOnlyExclusionIsRejected() {
        XCTAssertThrowsError(try Restriction(customExclusions: ["   "]), "a blank exclusion is meaningless, not a wildcard")
    }

    // MARK: - Item 5: offline caching requires an explicit grant (SPEC 3.5)

    private func license(
        cachingAllowed: RecipeLicense.Grant = .permitted,
        offlineUseAllowed: RecipeLicense.Grant = .permitted
    ) throws -> RecipeLicense {
        try RecipeLicense(
            textRedistribution: .permitted,
            imageRedistribution: .permitted,
            modificationAllowed: .permitted,
            attributionRequired: true,
            cachingAllowed: cachingAllowed,
            offlineUseAllowed: offlineUseAllowed,
            evidence: "Commission contract, signed 2026-09-30"
        )
    }

    func testUnknownCachingGrantQuarantines() throws {
        let licensed = try license(cachingAllowed: .unknown)
        XCTAssertTrue(licensed.isQuarantined, "unknown caching is quarantine, not permission (SPEC 3.5)")
    }

    func testForbiddenCachingGrantQuarantines() throws {
        let licensed = try license(cachingAllowed: .forbidden)
        XCTAssertTrue(licensed.isQuarantined)
    }

    func testExplicitCachingGrantIsNotQuarantined() throws {
        let licensed = try license()
        XCTAssertFalse(licensed.isQuarantined, "an explicit caching grant clears quarantine")
    }

    func testUnknownOfflineUseStillQuarantines() throws {
        XCTAssertTrue(try license(offlineUseAllowed: .unknown).isQuarantined)
    }

    /// Contract for the `mayCacheOffline` API added with item 5: the explicit
    /// grant decides, and quarantine from any offline-relevant right wins.
    /// (New-API contract test: green on arrival; the red state is documented
    /// as the compile-absence of `mayCacheOffline` captured in the red log.)
    func testMayCacheOfflineRequiresExplicitGrantOutsideQuarantine() throws {
        XCTAssertTrue(try license().mayCacheOffline)
        XCTAssertFalse(try license(cachingAllowed: .unknown).mayCacheOffline)
        XCTAssertFalse(try license(cachingAllowed: .forbidden).mayCacheOffline)
        // A clean caching grant cannot outvote a quarantine elsewhere.
        XCTAssertFalse(try license(offlineUseAllowed: .forbidden).mayCacheOffline)
    }

    // MARK: - Item 7: nutrition coverage exactness

    private func sampleValues() throws -> NutritionValues {
        try NutritionValues(caloriesKcal: 100, proteinGrams: 5)
    }

    func testPartialCoverageMustNameExactlyTheMissingLines() throws {
        let values = try sampleValues()
        // sodiumGrams and five more lines are missing; naming only sodium is a lie.
        XCTAssertThrowsError(
            try NutritionReport(values: values, coverage: .partial(missingLines: ["sodiumGrams"])),
            "partial coverage must equal the actual missing lines, not a subset"
        )
        // The exact missing set, in line order, is accepted.
        let missing = NutritionValues.lineNames.filter { $0 != "caloriesKcal" && $0 != "proteinGrams" }
        XCTAssertNoThrow(try NutritionReport(values: values, coverage: .partial(missingLines: missing)))
    }

    func testPartialCoverageRejectsUnknownNutrientNames() throws {
        let values = try sampleValues()
        XCTAssertThrowsError(
            try NutritionReport(values: values, coverage: .partial(missingLines: ["vitaminC"])),
            "a nutrient name outside the core lines is refused, never silently tolerated"
        )
    }
}
