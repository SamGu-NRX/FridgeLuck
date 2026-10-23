import Foundation
import FLDomain

// MARK: - Cooking challenges
// SPEC 6: challenges ("Three ingredients, what can you make?", budget packs,
// use-it-up, time limits, seasonal ones) work alone; progress is derived from
// Cook records, never claimed. Every counted and excluded cook carries its
// explanation, so the progress arithmetic is always explainable from the
// underlying records. Nothing here is a like count: the only number a
// challenge shows the household is their own progress toward their own goal.

/// What completes a challenge.
public struct ChallengeGoal: Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Cook the target number of DISTINCT recipe revisions (cooking the
        /// same dish twice demonstrates no new dish).
        case cookDistinctRecipes
        /// Cook the target number of times (use-it-up: leftovers count every
        /// time they save a meal).
        case cookTimes
    }

    public let kind: Kind
    /// At least 1.
    public let targetCount: Int

    public init(kind: Kind, targetCount: Int) throws {
        guard targetCount >= 1 else {
            throw FLDomainError.validation(target: "ChallengeGoal.targetCount", reason: "must be >= 1 (got \(targetCount))")
        }
        self.kind = kind
        self.targetCount = targetCount
    }
}

extension ChallengeGoal: Codable {
    private enum CodingKeys: String, CodingKey { case kind, targetCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: try container.decode(Kind.self, forKey: .kind),
            targetCount: try container.decode(Int.self, forKey: .targetCount)
        )
    }
}

/// A challenge's fixed rules: identity, window, goal, and (for
/// ingredient-constrained challenges like "3 ingredients") the required
/// ingredient set.
public struct ChallengeDefinition: Hashable, Sendable {
    /// Stable challenge identity. Never empty; at most 128 characters.
    public let id: String
    /// Display title, e.g. "Three ingredients: flour, milk, eggs". Never empty.
    public let title: String
    public let goal: ChallengeGoal
    /// Canonical ingredient names the cooked recipe's required (non-garnish)
    /// lines must cover, compared case-insensitively. Empty for challenges
    /// with no ingredient constraint (use-it-up, budget packs).
    public let requiredIngredientNames: [String]
    /// Inclusive window: a cook qualifies when `startsAt <= completedAt <= endsAt`.
    public let startsAt: Date
    public let endsAt: Date

    public init(
        id: String,
        title: String,
        goal: ChallengeGoal,
        requiredIngredientNames: [String] = [],
        startsAt: Date,
        endsAt: Date
    ) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw FLDomainError.validation(target: "ChallengeDefinition.id", reason: "must not be empty")
        }
        guard trimmedID.count <= 128 else {
            throw FLDomainError.validation(target: "ChallengeDefinition.id", reason: "must be at most 128 characters")
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw FLDomainError.validation(target: "ChallengeDefinition.title", reason: "must not be empty")
        }
        var names: [String] = []
        for raw in requiredIngredientNames {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw FLDomainError.validation(target: "ChallengeDefinition.requiredIngredientNames", reason: "must not contain empty names")
            }
            names.append(trimmed)
        }
        guard endsAt >= startsAt else {
            throw FLDomainError.validation(target: "ChallengeDefinition.endsAt", reason: "must be at or after startsAt")
        }
        self.id = trimmedID
        self.title = trimmedTitle
        self.goal = goal
        self.requiredIngredientNames = names
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

extension ChallengeDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, goal, requiredIngredientNames, startsAt, endsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            goal: try container.decode(ChallengeGoal.self, forKey: .goal),
            requiredIngredientNames: try container.decodeIfPresent([String].self, forKey: .requiredIngredientNames) ?? [],
            startsAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .startsAt),
                target: "ChallengeDefinition.startsAt"
            ),
            endsAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .endsAt),
                target: "ChallengeDefinition.endsAt"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(goal, forKey: .goal)
        try container.encode(requiredIngredientNames, forKey: .requiredIngredientNames)
        try container.encode(FLTimestamp.encode(startsAt), forKey: .startsAt)
        try container.encode(FLTimestamp.encode(endsAt), forKey: .endsAt)
    }
}

/// The household's participation in a challenge. Joining is idempotent;
/// completion is derived from records, never claimed by a caller.
public struct ChallengeEnrollment: Hashable, Sendable {
    public let challengeID: String
    public let joinedAt: Date
    /// Set when progress first met the goal. The instant is the completion
    /// timestamp of the cook record that crossed the threshold.
    public let completedAt: Date?
    /// The cook record that crossed the threshold, when completed.
    public let completedByCookID: String?

    public init(challengeID: String, joinedAt: Date, completedAt: Date? = nil, completedByCookID: String? = nil) throws {
        let trimmedID = challengeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw FLDomainError.validation(target: "ChallengeEnrollment.challengeID", reason: "must not be empty")
        }
        if let completedAt {
            guard completedAt >= joinedAt else {
                throw FLDomainError.validation(target: "ChallengeEnrollment.completedAt", reason: "must be at or after joinedAt")
            }
            guard completedByCookID != nil else {
                throw FLDomainError.validation(
                    target: "ChallengeEnrollment.completedByCookID",
                    reason: "a completion names the cook record that crossed the threshold; progress is derived from records, never claimed"
                )
            }
        } else if completedByCookID != nil {
            throw FLDomainError.validation(
                target: "ChallengeEnrollment.completedByCookID",
                reason: "cannot be set without a completion date"
            )
        }
        self.challengeID = trimmedID
        self.joinedAt = joinedAt
        self.completedAt = completedAt
        self.completedByCookID = completedByCookID
    }

    /// Join (idempotent amid retries and replays: joining an already-joined
    /// challenge returns the same enrollment).
    public static func join(definition: ChallengeDefinition, at joinedAt: Date, existing: ChallengeEnrollment?) throws -> ChallengeEnrollment {
        if let existing {
            guard existing.challengeID == definition.id else {
                throw FLDomainError.validation(
                    target: "ChallengeEnrollment.challengeID",
                    reason: "existing enrollment is for \(existing.challengeID), not \(definition.id)"
                )
            }
            return existing
        }
        return try ChallengeEnrollment(challengeID: definition.id, joinedAt: joinedAt)
    }
}

/// Why one cook record did not count toward the goal.
public enum ChallengeExclusionReason: String, Codable, Sendable, Equatable, CaseIterable {
    case outsideChallengeWindow
    case beforeJoin
    case unknownRecipeRevision
    case missingRequiredIngredients
    /// For `cookDistinctRecipes`: this cook repeated a revision already
    /// counted, so it does not advance the goal. It is still a real cook —
    /// it is listed with its explanation, never dropped.
    case duplicateOfCountedRevision
}

/// One cook record that counted, with the arithmetic that counted it.
public struct QualifyingCookRecord: Hashable, Sendable {
    public let cookID: String
    public let recipeKey: RecipeKey
    public let completedAt: Date
    /// Which required ingredients this cook's revision covered (canonical
    /// names, case-folded as matched). Empty when the challenge has none.
    public let coveredRequiredIngredients: [String]
}

/// One cook record that did not count, with the reason it did not.
public struct ExcludedCookRecord: Hashable, Sendable {
    public let cookID: String
    /// Known when the exclusion is not "unknown revision".
    public let recipeKey: RecipeKey?
    public let reason: ChallengeExclusionReason
    /// Optional detail lines (for example, the missing ingredient names), sorted
    /// canonically by the evaluator; empty for the common no-detail case.
    public let detail: [String]
}

/// The progress of one household in one challenge — every cook accounted for,
/// none invisible.
public struct ChallengeProgress: Hashable, Sendable {
    public let challengeID: String
    public let goal: ChallengeGoal
    /// Cook records that counted, in input order.
    public let qualifying: [QualifyingCookRecord]
    /// Cook records that did not count, each with its reason, in input order.
    public let excluded: [ExcludedCookRecord]

    public init(challengeID: String, goal: ChallengeGoal, qualifying: [QualifyingCookRecord], excluded: [ExcludedCookRecord]) throws {
        let trimmedID = challengeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw FLDomainError.validation(target: "ChallengeProgress.challengeID", reason: "must not be empty")
        }
        self.challengeID = trimmedID
        self.goal = goal
        self.qualifying = qualifying
        self.excluded = excluded
    }

    /// The count the goal is measured on, capped at the target: distinct
    /// revisions or qualifying cooks, per the goal kind. This is the whole
    /// arithmetic.
    public var counted: Int {
        switch goal.kind {
        case .cookDistinctRecipes:
            var seen = Set<RecipeKey>()
            for record in qualifying {
                if seen.insert(record.recipeKey).inserted, seen.count >= goal.targetCount { break }
            }
            return seen.count
        case .cookTimes:
            return min(qualifying.count, goal.targetCount)
        }
    }

    public var isComplete: Bool { counted >= goal.targetCount }

    /// The instant the goal was crossed, and the cook that crossed it —
    /// derived from the qualifying records, never claimed.
    public var completion: (date: Date, cookID: String)? {
        switch goal.kind {
        case .cookDistinctRecipes:
            var seen = Set<RecipeKey>()
            for record in qualifying {
                if seen.insert(record.recipeKey).inserted, seen.count == goal.targetCount {
                    return (record.completedAt, record.cookID)
                }
            }
            return nil
        case .cookTimes:
            guard qualifying.count >= goal.targetCount else { return nil }
            return (qualifying[goal.targetCount - 1].completedAt, qualifying[goal.targetCount - 1].cookID)
        }
    }
}

extension ChallengeProgress: Codable {
    private enum CodingKeys: String, CodingKey { case challengeID, goal, qualifying, excluded }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            challengeID: try container.decode(String.self, forKey: .challengeID),
            goal: try container.decode(ChallengeGoal.self, forKey: .goal),
            qualifying: try container.decodeIfPresent([QualifyingCookRecord].self, forKey: .qualifying) ?? [],
            excluded: try container.decodeIfPresent([ExcludedCookRecord].self, forKey: .excluded) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(challengeID, forKey: .challengeID)
        try container.encode(goal, forKey: .goal)
        try container.encode(qualifying, forKey: .qualifying)
        try container.encode(excluded, forKey: .excluded)
    }
}

extension QualifyingCookRecord: Codable {
    private enum CodingKeys: String, CodingKey { case cookID, recipeKey, completedAt, coveredRequiredIngredients }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cookID: try container.decode(String.self, forKey: .cookID),
            recipeKey: try container.decode(RecipeKey.self, forKey: .recipeKey),
            completedAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .completedAt),
                target: "QualifyingCookRecord.completedAt"
            ),
            coveredRequiredIngredients: try container.decodeIfPresent([String].self, forKey: .coveredRequiredIngredients) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cookID, forKey: .cookID)
        try container.encode(recipeKey, forKey: .recipeKey)
        try container.encode(FLTimestamp.encode(completedAt), forKey: .completedAt)
        try container.encode(coveredRequiredIngredients, forKey: .coveredRequiredIngredients)
    }
}

extension ExcludedCookRecord: Codable {
    private enum CodingKeys: String, CodingKey { case cookID, recipeKey, reason, detail }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cookID: try container.decode(String.self, forKey: .cookID),
            recipeKey: try container.decodeIfPresent(RecipeKey.self, forKey: .recipeKey),
            reason: try container.decode(ChallengeExclusionReason.self, forKey: .reason),
            detail: try container.decodeIfPresent([String].self, forKey: .detail) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cookID, forKey: .cookID)
        try container.encodeIfPresent(recipeKey, forKey: .recipeKey)
        try container.encode(reason, forKey: .reason)
        try container.encode(detail, forKey: .detail)
    }
}

/// Derives challenge progress from finished-cook records.
///
/// Rules, each test-frozen:
/// - only cooks completed at or after `joinedAt` count (joining does not
///   retroactively credit earlier cooks);
/// - only cooks inside the challenge window count (`startsAt <= completedAt
///   <= endsAt`, both ends inclusive);
/// - a cook counts when its revision's required (non-garnish) lines cover
///   every required ingredient, case-insensitively; substitutions do not
///   satisfy requirements (the revision they cooked is what they cooked);
/// - under `cookDistinctRecipes` a repeat of an already-counted revision is
///   excluded with `.duplicateOfCountedRevision`, never silently dropped;
/// - duplicate cook IDs in the input are a caller error and throw.
public enum ChallengeEvaluator {
    public static func progress(
        definition: ChallengeDefinition,
        enrollment: ChallengeEnrollment?,
        cooks: [Cook],
        revisionFor: (RecipeKey) -> RecipeRevision?
    ) throws -> ChallengeProgress {
        var seenCookIDs = Set<String>()
        for cook in cooks {
            guard seenCookIDs.insert(cook.id).inserted else {
                throw FLDomainError.validation(
                    target: "ChallengeEvaluator.cooks",
                    reason: "duplicate cook record id \(cook.id)"
                )
            }
        }

        let required = definition.requiredIngredientNames.map { $0.lowercased() }
        var qualifying: [QualifyingCookRecord] = []
        var excluded: [ExcludedCookRecord] = []
        var countedRevisions = Set<RecipeKey>()

        for cook in cooks {
            if let enrollment, cook.completedAt < enrollment.joinedAt {
                excluded.append(ExcludedCookRecord(cookID: cook.id, recipeKey: cook.recipeRevision, reason: .beforeJoin, detail: []))
                continue
            }
            guard cook.completedAt >= definition.startsAt, cook.completedAt <= definition.endsAt else {
                excluded.append(ExcludedCookRecord(cookID: cook.id, recipeKey: cook.recipeRevision, reason: .outsideChallengeWindow, detail: []))
                continue
            }
            guard let revision = revisionFor(cook.recipeRevision) else {
                excluded.append(ExcludedCookRecord(cookID: cook.id, recipeKey: cook.recipeRevision, reason: .unknownRecipeRevision, detail: []))
                continue
            }
            let covered = Set(revision.requiredIngredientLines.map { $0.ingredient.canonicalName.lowercased() })
            let missing = required.filter { !covered.contains($0) }
            guard missing.isEmpty else {
                excluded.append(ExcludedCookRecord(
                    cookID: cook.id,
                    recipeKey: cook.recipeRevision,
                    reason: .missingRequiredIngredients,
                    detail: missing
                ))
                continue
            }
            if definition.goal.kind == .cookDistinctRecipes, !countedRevisions.insert(cook.recipeRevision).inserted {
                excluded.append(ExcludedCookRecord(cookID: cook.id, recipeKey: cook.recipeRevision, reason: .duplicateOfCountedRevision, detail: []))
                continue
            }
            qualifying.append(QualifyingCookRecord(
                cookID: cook.id,
                recipeKey: cook.recipeRevision,
                completedAt: cook.completedAt,
                coveredRequiredIngredients: required
            ))
        }

        return try ChallengeProgress(
            challengeID: definition.id,
            goal: definition.goal,
            qualifying: qualifying,
            excluded: excluded
        )
    }

    /// Progress plus the enrollment updated for completion: when progress
    /// first met the goal, `completedAt` is the completion instant of the
    /// cook record that crossed the threshold. Already-completed enrollments
    /// keep their original completion (completion is not re-dated).
    public static func evaluate(
        definition: ChallengeDefinition,
        enrollment: ChallengeEnrollment?,
        cooks: [Cook],
        revisionFor: (RecipeKey) -> RecipeRevision?
    ) throws -> (progress: ChallengeProgress, enrollment: ChallengeEnrollment?) {
        let progress = try progress(definition: definition, enrollment: enrollment, cooks: cooks, revisionFor: revisionFor)
        guard let enrollment else { return (progress, nil) }
        if enrollment.completedAt != nil { return (progress, enrollment) }
        guard progress.isComplete, let completion = progress.completion else {
            return (progress, enrollment)
        }
        let completed = try ChallengeEnrollment(
            challengeID: enrollment.challengeID,
            joinedAt: enrollment.joinedAt,
            completedAt: completion.date,
            completedByCookID: completion.cookID
        )
        return (progress, completed)
    }
}
