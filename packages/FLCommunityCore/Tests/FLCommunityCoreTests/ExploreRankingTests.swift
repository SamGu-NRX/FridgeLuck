import XCTest
import FLDomain
@testable import FLCommunityCore

/// Explore ranking is pure, deterministic and explainable. The tests freeze:
/// combined-score ordering with the fit-first default, the cold-start neutral
/// prior, stable tie-breaks, per-entry explanations, input validation, and
/// that the output does not depend on input order. There is no popularity
/// signal and no taste data leaves the caller.
final class ExploreRankingTests: XCTestCase {
    // MARK: Helpers

    private func candidate(
        slug: String,
        title: String,
        fit: Double,
        taste: Double? = nil,
        revisionNumber: Int = 1
    ) throws -> ExploreCandidate {
        try ExploreCandidate(
            revision: try TestSupport.revision(slug: slug, revisionNumber: revisionNumber, license: TestSupport.license(), title: title),
            fit: fit,
            taste: taste
        )
    }

    private func assertValidation(
        target: String,
        reasonContains: String? = nil,
        _ body: () throws -> Void
    ) throws {
        XCTAssertThrowsError(try body()) { error in
            guard case let FLDomainError.validation(actualTarget, reason) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(actualTarget, target)
            if let reasonContains {
                XCTAssertTrue(reason.contains(reasonContains), "unexpected reason: \(reason)")
            }
        }
    }

    // MARK: Ordering

    func testOrdersByCombinedScore() throws {
        let entries = try ExploreRanking.rank(candidates: [
            try candidate(slug: "strong-fit", title: "Strong fit", fit: 0.9, taste: 0.4),
            try candidate(slug: "strong-taste", title: "Strong taste", fit: 0.5, taste: 0.9),
            try candidate(slug: "middle", title: "Middle", fit: 0.7, taste: 0.65),
        ])
        // 0.9·0.6 + 0.4·0.4 = 0.70; 0.5·0.6 + 0.9·0.4 = 0.66; 0.7·0.6 + 0.65·0.4 = 0.68
        XCTAssertEqual(entries.map { $0.candidate.revision.title }, ["Strong fit", "Middle", "Strong taste"])
        XCTAssertEqual(entries.map { $0.score }, [0.70, 0.68, 0.66])
    }

    func testColdStartScoresAtTheNeutralPrior() throws {
        let cold = try candidate(slug: "cold", title: "Cold start", fit: 0.8, taste: nil)
        let warm = try candidate(slug: "warm", title: "Warm", fit: 0.8, taste: 0.5, revisionNumber: 2)
        let entries = try ExploreRanking.rank(candidates: [cold, warm])
        XCTAssertEqual(entries.map { $0.score }, [0.68, 0.68], "a missing taste signal scores exactly at the prior")
        XCTAssertEqual(entries.first?.candidate.revision.title, "Cold start", "the tie breaks by title")
        XCTAssertTrue(entries.first!.explanation.contains("taste 0.500 × 0.400 (neutral prior)"))
        XCTAssertTrue(entries.last!.explanation.contains("taste 0.500 × 0.400 (household signal)"))
    }

    func testWeightsShapeTheOrder() throws {
        let fitStrong = try candidate(slug: "fit-strong", title: "Fit strong", fit: 0.9, taste: 0.2)
        let tasteStrong = try candidate(slug: "taste-strong", title: "Taste strong", fit: 0.5, taste: 0.95)
        // Default (fit-first): 0.62 vs 0.68 — taste wins.
        let defaultOrder = try ExploreRanking.rank(candidates: [fitStrong, tasteStrong])
        XCTAssertEqual(defaultOrder.first?.candidate.revision.title, "Taste strong")
        // All-fit: 0.9 vs 0.5 — fit wins.
        let allFit = try ExploreRanking.rank(
            candidates: [fitStrong, tasteStrong],
            weights: try .validated(fit: 1.0, taste: 0.0)
        )
        XCTAssertEqual(allFit.first?.candidate.revision.title, "Fit strong")
    }

    // MARK: Determinism and ties

    func testRankingIsIndependentOfInputOrder() throws {
        let a = try candidate(slug: "alpha", title: "Alpha", fit: 0.9, taste: 0.8)
        let b = try candidate(slug: "beta", title: "Beta", fit: 0.7, taste: 0.6)
        let c = try candidate(slug: "gamma", title: "Gamma", fit: 0.5, taste: 0.9)
        let shuffled = try ExploreRanking.rank(candidates: [c, a, b])
        let ordered = try ExploreRanking.rank(candidates: [a, b, c])
        XCTAssertEqual(shuffled, ordered, "the same catalog ranks identically regardless of input order")
    }

    func testEqualScoresBreakByTitleThenKey() throws {
        let sameScoreA = try candidate(slug: "zzz", title: "Same", fit: 0.9, taste: 0.5)
        let sameScoreB = try candidate(slug: "aaa", title: "Same", fit: 0.9, taste: 0.5, revisionNumber: 2)
        let entries = try ExploreRanking.rank(candidates: [sameScoreA, sameScoreB])
        XCTAssertEqual(entries.map { $0.candidate.revision.key.sourceRecipeID }, ["aaa", "zzz"], "title ties break by key description")
    }

    // MARK: Explanations

    func testEveryEntryExplainsItsScore() throws {
        let entries = try ExploreRanking.rank(candidates: [
            try candidate(slug: "one", title: "One", fit: 0.75, taste: 0.6),
            try candidate(slug: "two", title: "Two", fit: 0.4),
        ])
        for entry in entries {
            XCTAssertEqual(entry.explanation.count, 3)
            XCTAssertTrue(entry.explanation[0].hasPrefix("cookability"))
            XCTAssertTrue(entry.explanation[1].hasPrefix("taste"))
            XCTAssertTrue(entry.explanation[2].hasPrefix("combined"))
            // The combined line restates the score to six decimals.
            XCTAssertEqual(entry.explanation[2], String(format: "combined %.6f", entry.score))
            // The score is the weighted sum of the components.
            XCTAssertEqual(entry.score, entry.fitComponent + entry.tasteComponent, accuracy: 1e-9)
        }
    }

    // MARK: Validation

    func testRefusesFitOutsideUnitInterval() throws {
        for fit in [-0.01, 1.01] {
            try assertValidation(target: "ExploreCandidate.fit", reasonContains: "0...1") {
                _ = try candidate(slug: "bad-fit", title: "Bad fit", fit: fit)
            }
        }
    }

    func testRefusesTasteOutsideUnitInterval() throws {
        try assertValidation(target: "ExploreCandidate.taste", reasonContains: "0...1") {
            _ = try candidate(slug: "bad-taste", title: "Bad taste", fit: 0.5, taste: 1.5)
        }
    }

    func testRefusesDuplicateCandidateKeys() throws {
        let a = try candidate(slug: "dup", title: "Dup", fit: 0.5)
        let b = try candidate(slug: "dup", title: "Dup again", fit: 0.9, revisionNumber: 1)
        try assertValidation(target: "ExploreRanking.candidates", reasonContains: "duplicate candidate key") {
            _ = try ExploreRanking.rank(candidates: [a, b])
        }
    }

    func testWeightsAreValidated() throws {
        for (fit, taste) in [(-0.1, 0.5), (0.5, 1.1), (0.0, 0.0)] {
            try assertValidation(target: "ExploreRankWeights", reasonContains: "positive sum") {
                _ = try ExploreRankWeights.validated(fit: fit, taste: taste)
            }
        }
        XCTAssertNil(ExploreRankWeights(fit: 1.2, taste: 0.4))
        XCTAssertNotNil(ExploreRankWeights.default)
    }

    func testEmptyCatalogRanksToEmpty() throws {
        XCTAssertEqual(try ExploreRanking.rank(candidates: []), [])
    }
}
