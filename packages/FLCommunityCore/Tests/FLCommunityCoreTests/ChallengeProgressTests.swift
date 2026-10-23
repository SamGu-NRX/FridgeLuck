import XCTest
import FLDomain
@testable import FLCommunityCore

/// Challenges: progress is derived from Cook records, never claimed, and
/// every counted and excluded cook carries its explanation. SPEC 6.
final class ChallengeProgressTests: XCTestCase {
    private let window = (start: "2026-10-01T00:00:00.000Z", end: "2026-10-31T23:59:59.000Z")

    private func definition(
        goal: ChallengeGoal,
        required: [String] = []
    ) throws -> ChallengeDefinition {
        try ChallengeDefinition(
            id: "challenge-october",
            title: "October cook-more",
            goal: goal,
            requiredIngredientNames: required,
            startsAt: try TestSupport.date(window.start),
            endsAt: try TestSupport.date(window.end)
        )
    }

    private func joined(at iso: String = "2026-10-01T12:00:00.000Z") throws -> ChallengeEnrollment {
        try ChallengeEnrollment(challengeID: "challenge-october", joinedAt: try TestSupport.date(iso))
    }

    private func evaluate(
        definition: ChallengeDefinition,
        enrollment: ChallengeEnrollment?,
        cooks: [Cook],
        revisions: [RecipeRevision]
    ) throws -> (progress: ChallengeProgress, enrollment: ChallengeEnrollment?) {
        try ChallengeEvaluator.evaluate(
            definition: definition,
            enrollment: enrollment,
            cooks: cooks,
            revisionFor: { key in revisions.first { $0.key == key } }
        )
    }

    // MARK: Qualification rules

    func testCooksBeforeJoinAreExcludedNotDropped() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1))
        let revision = try TestSupport.revision(license: TestSupport.license())
        let cook = try TestSupport.cook(
            id: "cook-early",
            key: revision.key,
            completedAt: try TestSupport.date("2026-10-01T11:00:00.000Z") // before the 12:00 join
        )
        let result = try evaluate(definition: definition, enrollment: try joined(), cooks: [cook], revisions: [revision])
        XCTAssertEqual(result.progress.qualifying, [])
        XCTAssertEqual(result.progress.excluded.first?.cookID, "cook-early")
        XCTAssertEqual(result.progress.excluded.first?.reason, .beforeJoin)
        XCTAssertFalse(result.progress.isComplete)
    }

    func testCooksOutsideTheWindowAreExcluded() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1))
        let revision = try TestSupport.revision(license: TestSupport.license())
        let cook = try TestSupport.cook(id: "cook-sept", key: revision.key, completedAt: try TestSupport.date("2026-09-30T23:00:00.000Z"))
        let result = try evaluate(definition: definition, enrollment: nil, cooks: [cook], revisions: [revision])
        XCTAssertEqual(result.progress.excluded.first?.reason, .outsideChallengeWindow)
    }

    func testWindowBoundariesAreInclusive() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1))
        let revision = try TestSupport.revision(license: TestSupport.license())
        for iso in [window.start, window.end] {
            let cook = try TestSupport.cook(id: "cook-\(iso)", key: revision.key, completedAt: try TestSupport.date(iso))
            let result = try evaluate(definition: definition, enrollment: nil, cooks: [cook], revisions: [revision])
            XCTAssertEqual(result.progress.counted, 1, "\(iso) must count (inclusive bounds)")
        }
    }

    func testUnknownRevisionIsExcludedWithItsRecord() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1))
        let revision = try TestSupport.revision(license: TestSupport.license())
        let ghostKey = try RecipeKey(source: .community, sourceRecipeID: "ghost", revision: 9)
        let cook = try TestSupport.cook(id: "cook-ghost", key: ghostKey, completedAt: try TestSupport.date("2026-10-05T10:00:00.000Z"))
        let result = try evaluate(definition: definition, enrollment: nil, cooks: [cook], revisions: [revision])
        XCTAssertEqual(result.progress.excluded.first?.reason, .unknownRecipeRevision)
        XCTAssertEqual(result.progress.excluded.first?.recipeKey, ghostKey)
    }

    func testMissingRequiredIngredientIsExcludedWithTheMissingNames() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1), required: ["paneer", "coriander"])
        // Cooked revision has paneer but no coriander.
        let revision = try TestSupport.revision(license: TestSupport.license(), ingredients: ["paneer", "yogurt"])
        let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: try TestSupport.date("2026-10-05T10:00:00.000Z"))
        let result = try evaluate(definition: definition, enrollment: nil, cooks: [cook], revisions: [revision])
        XCTAssertEqual(result.progress.excluded.first?.reason, .missingRequiredIngredients)
        XCTAssertEqual(result.progress.excluded.first?.detail, ["coriander"])
    }

    func testRequiredIngredientsMatchCaseInsensitivelyAndGarnishNeverCounts() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1), required: ["PANEER"])
        // "paneer" only on an optional garnish line: not covered.
        let garnishOnly = try TestSupport.revision(license: TestSupport.license(), ingredients: ["rice"], garnish: ["Paneer"])
        let covered = try TestSupport.revision(slug: "paneer-covered", license: TestSupport.license(), ingredients: ["Paneer"])
        let cookA = try TestSupport.cook(id: "cook-a", key: garnishOnly.key, completedAt: try TestSupport.date("2026-10-05T10:00:00.000Z"))
        let cookB = try TestSupport.cook(id: "cook-b", key: covered.key, completedAt: try TestSupport.date("2026-10-06T10:00:00.000Z"))
        let result = try evaluate(definition: definition, enrollment: nil, cooks: [cookA, cookB], revisions: [garnishOnly, covered])
        XCTAssertEqual(result.progress.excluded.first?.reason, .missingRequiredIngredients)
        XCTAssertEqual(result.progress.qualifying.count, 1)
        XCTAssertEqual(result.progress.qualifying.first?.cookID, "cook-b")
    }

    func testSubstitutionsDoNotSatisfyRequiredIngredients() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1), required: ["paneer"])
        // The cook swapped paneer away; the revision they cooked still lists
        // paneer (the swap is cook history, not the recipe).
        let revision = try TestSupport.revision(license: TestSupport.license(), ingredients: ["paneer"])
        let cook = try TestSupport.cook(
            id: "cook-swap",
            key: revision.key,
            completedAt: try TestSupport.date("2026-10-05T10:00:00.000Z"),
            substitutions: [try TestSupport.substitution(from: "paneer", to: "tofu", necessity: .necessary)]
        )
        let result = try evaluate(definition: definition, enrollment: nil, cooks: [cook], revisions: [revision])
        XCTAssertEqual(result.progress.qualifying.count, 1)
        XCTAssertEqual(result.progress.qualifying.first?.coveredRequiredIngredients, ["paneer"])
    }

    // MARK: Goal arithmetic, explainable per record

    func testDistinctRecipesGoalIgnoresRepeatsAndExplainsThem() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookDistinctRecipes, targetCount: 2))
        let revisionA = try TestSupport.revision(slug: "paneer-tikka", license: TestSupport.license())
        let revisionB = try TestSupport.revision(slug: "shakshuka", revisionNumber: 1, license: TestSupport.license())
        let repeatA = try TestSupport.revision(slug: "paneer-tikka", license: TestSupport.license())
        let cooks = [
            try TestSupport.cook(id: "cook-1", key: revisionA.key, completedAt: try TestSupport.date("2026-10-03T10:00:00.000Z")),
            try TestSupport.cook(id: "cook-2", key: repeatA.key, completedAt: try TestSupport.date("2026-10-04T10:00:00.000Z")),
            try TestSupport.cook(id: "cook-3", key: revisionB.key, completedAt: try TestSupport.date("2026-10-05T10:00:00.000Z")),
        ]
        let result = try evaluate(definition: definition, enrollment: try joined(), cooks: cooks, revisions: [revisionA, revisionB])
        XCTAssertEqual(result.progress.qualifying.map(\.cookID), ["cook-1", "cook-3"])
        XCTAssertEqual(result.progress.excluded.map(\.cookID), ["cook-2"])
        XCTAssertEqual(result.progress.excluded.first?.reason, .duplicateOfCountedRevision)
        XCTAssertEqual(result.progress.counted, 2)
        XCTAssertTrue(result.progress.isComplete)
    }

    func testCookTimesGoalCountsEveryQualifyingCook() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 3))
        let revision = try TestSupport.revision(license: TestSupport.license())
        let cooks = try (1...4).map { index in
            try TestSupport.cook(id: "cook-\(index)", key: revision.key, completedAt: try TestSupport.date("2026-10-0\(index + 1)T10:00:00.000Z"))
        }
        let result = try evaluate(definition: definition, enrollment: try joined(), cooks: cooks, revisions: [revision])
        XCTAssertEqual(result.progress.counted, 3, "capped at the target for display")
        XCTAssertTrue(result.progress.isComplete)
    }

    func testCompletionNamesTheCrossingCook() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookDistinctRecipes, targetCount: 2))
        let revisionA = try TestSupport.revision(slug: "a", license: TestSupport.license())
        let revisionB = try TestSupport.revision(slug: "b", revisionNumber: 1, license: TestSupport.license())
        let cooks = [
            try TestSupport.cook(id: "cook-1", key: revisionA.key, completedAt: try TestSupport.date("2026-10-03T10:00:00.000Z")),
            try TestSupport.cook(id: "cook-2", key: revisionA.key, completedAt: try TestSupport.date("2026-10-04T10:00:00.000Z")), // repeat
            try TestSupport.cook(id: "cook-3", key: revisionB.key, completedAt: try TestSupport.date("2026-10-05T10:00:00.000Z")), // crosses
        ]
        let (progress, enrollment) = try evaluate(definition: definition, enrollment: try joined(), cooks: cooks, revisions: [revisionA, revisionB])
        let completion = try XCTUnwrap(progress.completion)
        XCTAssertEqual(completion.cookID, "cook-3")
        XCTAssertEqual(completion.date, try TestSupport.date("2026-10-05T10:00:00.000Z"))
        let completed = try XCTUnwrap(enrollment)
        XCTAssertEqual(completed.completedAt, completion.date)
        XCTAssertEqual(completed.completedByCookID, "cook-3")
    }

    func testCompletionIsNotRedatedOnReevaluation() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1))
        let revision = try TestSupport.revision(license: TestSupport.license())
        let alreadyComplete = try ChallengeEnrollment(
            challengeID: "challenge-october",
            joinedAt: try TestSupport.date("2026-10-01T12:00:00.000Z"),
            completedAt: try TestSupport.date("2026-10-02T10:00:00.000Z"),
            completedByCookID: "cook-1"
        )
        let newCook = try TestSupport.cook(id: "cook-9", key: revision.key, completedAt: try TestSupport.date("2026-10-09T10:00:00.000Z"))
        let (_, enrollment) = try evaluate(definition: definition, enrollment: alreadyComplete, cooks: [newCook], revisions: [revision])
        XCTAssertEqual(enrollment?.completedAt, try TestSupport.date("2026-10-02T10:00:00.000Z"), "completion is not re-dated")
    }

    func testJoinIsIdempotentAndRejectsMismatchedChallenges() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1))
        let first = try ChallengeEnrollment.join(definition: definition, at: try TestSupport.date("2026-10-01T12:00:00.000Z"), existing: nil)
        let again = try ChallengeEnrollment.join(definition: definition, at: try TestSupport.date("2026-10-02T12:00:00.000Z"), existing: first)
        XCTAssertEqual(again, first, "joining twice returns the same enrollment")
        let other = try ChallengeDefinition(
            id: "challenge-other",
            title: "Other",
            goal: ChallengeGoal(kind: .cookTimes, targetCount: 1),
            startsAt: try TestSupport.date(window.start),
            endsAt: try TestSupport.date(window.end)
        )
        XCTAssertThrowsError(try ChallengeEnrollment.join(definition: other, at: Date(timeIntervalSince1970: 0), existing: first))
    }

    func testEnrollmentCompletionRequiresItsCrossingCook() throws {
        XCTAssertThrowsError(try ChallengeEnrollment(
            challengeID: "challenge-october",
            joinedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 10),
            completedByCookID: nil
        ))
        XCTAssertThrowsError(try ChallengeEnrollment(
            challengeID: "challenge-october",
            joinedAt: Date(timeIntervalSince1970: 0),
            completedAt: nil,
            completedByCookID: "cook-1"
        ))
    }

    func testDuplicateCookIDsAndBadDefinitionsThrow() throws {
        let definition = try definition(goal: ChallengeGoal(kind: .cookTimes, targetCount: 1))
        let revision = try TestSupport.revision(license: TestSupport.license())
        let cook = try TestSupport.cook(id: "cook-1", key: revision.key, completedAt: try TestSupport.date("2026-10-05T10:00:00.000Z"))
        XCTAssertThrowsError(try evaluate(definition: definition, enrollment: nil, cooks: [cook, cook], revisions: [revision]))
        XCTAssertThrowsError(try ChallengeGoal(kind: .cookTimes, targetCount: 0))
        XCTAssertThrowsError(try ChallengeDefinition(
            id: "challenge-x",
            title: "X",
            goal: ChallengeGoal(kind: .cookTimes, targetCount: 1),
            requiredIngredientNames: ["  "],
            startsAt: try TestSupport.date(window.start),
            endsAt: try TestSupport.date(window.end)
        ))
        XCTAssertThrowsError(try ChallengeDefinition(
            id: "challenge-x",
            title: "X",
            goal: ChallengeGoal(kind: .cookTimes, targetCount: 1),
            startsAt: try TestSupport.date(window.end),
            endsAt: try TestSupport.date(window.start)
        ))
    }

    func testEveryExclusionReasonIsEnumerated() throws {
        // The reason enum is a contract with the UI: adding a reason must be
        // a conscious change.
        XCTAssertEqual(Set(ChallengeExclusionReason.allCases), [
            .outsideChallengeWindow, .beforeJoin, .unknownRecipeRevision,
            .missingRequiredIngredients, .duplicateOfCountedRevision,
        ])
    }
}
