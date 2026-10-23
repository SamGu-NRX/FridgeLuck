import Foundation

/// One entry in the append-only event log.
///
/// Events are facts about what happened; they are never edited. A mistake is
/// repaired by a `correction` event that references the event it amends.
/// Ingest is idempotent by `id`: replaying a duplicate id is a no-op.
public struct TasteEvent: Hashable, Sendable {
    public let id: EventID
    /// UTC timestamp. Replay orders by this, then by id, so any ingest order
    /// produces the same fold.
    public let at: Instant
    /// The eater this event belongs to. `nil` means a household-level event:
    /// explicit edits apply to the household layer, behavioural events apply
    /// to every eater known at fold time.
    public let eater: EaterID?
    /// Exposure context at decision time: how many candidates were feasible
    /// and how many were actually shown. Available variety separates "cooked
    /// what was shown" from "chose from real variety" (SPEC 3.3).
    public let exposure: ExposureContext?
    public let kind: EventKind

    public init(
        id: EventID, at: Instant, eater: EaterID?, exposure: ExposureContext?, kind: EventKind
    ) {
        self.id = id
        self.at = at
        self.eater = eater
        self.exposure = exposure
        self.kind = kind
    }
}

/// What was visible to the user when they acted. `feasibleCandidates` is the
/// size of the set that passed hard filters; `shownCandidates` is how many of
/// those the app actually displayed. `shownCandidates` must not exceed
/// `feasibleCandidates`.
public struct ExposureContext: Hashable, Sendable {
    public enum ContextError: Error, Equatable {
        /// feasible < 1, or shown outside 1...feasible.
        case invalidCounts
    }

    public let feasibleCandidates: Int
    public let shownCandidates: Int?

    /// Throws on an infeasible or inconsistent context.
    public init(feasibleCandidates: Int, shownCandidates: Int? = nil) throws {
        guard feasibleCandidates >= 1 else { throw ContextError.invalidCounts }
        if let shown = shownCandidates, shown < 1 || shown > feasibleCandidates {
            throw ContextError.invalidCounts
        }
        self.feasibleCandidates = feasibleCandidates
        self.shownCandidates = shownCandidates
    }
}

// MARK: - Event kinds (discriminated union; every variant is a fact)

public enum EventKind: Hashable, Sendable {
    /// Recipe appeared on a surface. No click yet — the weakest signal.
    case viewed(recipe: RecipeID)
    /// Recipe detail opened.
    case opened(recipe: RecipeID)
    /// Recipe saved to the cookbook.
    case saved(recipe: RecipeID)
    /// Recipe cooked. `rating` is 1...5 when the user rated;
    /// `wouldMakeAgain` when the user answered the cook-complete question.
    case cooked(recipe: RecipeID, rating: Rating?, wouldMakeAgain: Bool?)
    /// Recipe dismissed from a surface, with a typed reason.
    case skipped(recipe: RecipeID, reason: SkipReason)
    /// Ingredient replaced inside a recipe. `mode` is set only when the user
    /// said whether the swap was necessary or preferred.
    case substituted(recipe: RecipeID, from: IngredientID, to: IngredientID?, mode: SubstitutionMode?)
    /// Servings edited before or during a cook.
    case editedServings(recipe: RecipeID, from: Int, to: Int)
    /// Structured feedback from the LeChef cook companion.
    case leChefFeedback(recipe: RecipeID, feedback: LeChefFeedback)
    /// A direct edit of the explicit layers (restrictions, stated
    /// preferences, never-suggest list).
    case profileEdit(ProfileEditOp)
    /// Amends an earlier event; see `CorrectionResolution`.
    case correction(amends: EventID, resolution: CorrectionResolution)
}

/// A cook rating constrained to 1...5 at construction.
public struct Rating: Hashable, Comparable, Sendable {
    public let value: Int

    public init?(_ value: Int) {
        guard value >= 1 && value <= 5 else { return nil }
        self.value = value
    }

    public static func < (lhs: Rating, rhs: Rating) -> Bool { lhs.value < rhs.value }
}

public enum SkipReason: String, Hashable, Codable, Sendable {
    case outOfTime
    case missingIngredients
    case changedMind
    case other
}

public enum SubstitutionMode: String, Hashable, Codable, Sendable {
    /// The user lacked the ingredient; the swap says nothing about taste.
    case necessary
    /// The user preferred the substitute; mild negative evidence on the
    /// replaced ingredient.
    case preferred
}

public struct LeChefFeedback: Hashable, Sendable {
    public enum FeedbackType: String, Hashable, Codable, Sendable {
        case tooSpicy, tookTooLong, tooBland, portionWrong, other
    }

    public let type: FeedbackType
    /// Free text from the user; never leaves the device.
    public let note: String?

    public init(type: FeedbackType, note: String?) {
        self.type = type
        self.note = (note?.isEmpty ?? true) ? nil : note
    }
}

// MARK: - Corrections

/// What a correction does to the event it amends.
public enum CorrectionResolution: Hashable, Sendable {
    /// Remove the amended event's contribution to learning entirely.
    case void
    /// Fix the rating of an amended `cooked` event.
    case setRating(Rating)
    /// Fix the "would make again" answer of an amended `cooked` event.
    case setWouldMakeAgain(Bool)
    /// Re-attribute the amended event to a different eater.
    case reattribute(to: EaterID)
}

// MARK: - Explicit edits (the only events that write the explicit layers)

public enum ProfileEditOp: Hashable, Sendable {
    /// A hard restriction: an allergy or a diet exclusion. Hard filters are
    /// never weakened by taste and survive any learning reset (SPEC 3.3).
    case setRestriction(Restriction)
    case clearRestriction(restrictionKey: Restriction)
    /// A stated preference such as "likes it hot" or "prefers vegetarian
    /// weeknights". Acts as a prior, never as a filter.
    case setPreference(feature: FeatureKey, polarity: Polarity)
    case clearPreference(feature: FeatureKey)
    /// The user-written "Never suggest" list (mock: the only list the user
    /// writes directly). Stronger than any learned frequency (SPEC 3.3).
    case setNeverSuggest(ingredient: IngredientID)
    case clearNeverSuggest(ingredient: IngredientID)
}

/// Why an ingredient or diet is excluded. `allergy` is the safety-critical
/// variant; both are hard filters.
public struct Restriction: Hashable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case allergy
        case diet
    }

    public let kind: Kind
    /// Ingredient id for allergies ("peanut_butter" covers peanut allergy in
    /// the 50-ingredient catalog); diet tag for diets ("vegetarian").
    public let target: String
    /// Where it came from: setup or a later explicit edit. Setup-sourced
    /// restrictions are labelled and edited in setup, per the mock.
    public let source: String

    public init(kind: Kind, target: String, source: String) {
        self.kind = kind
        self.target = target
        self.source = source
    }
}

public enum Polarity: String, Hashable, Codable, Sendable {
    case like
    case dislike
}
