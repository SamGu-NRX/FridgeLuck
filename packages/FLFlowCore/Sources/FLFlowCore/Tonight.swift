import Foundation
import FLDomain

// MARK: - Meal context
// SPEC 2: meal context — who is eating, portions, time, equipment. Hard
// restrictions are the union of all eaters'.

/// One eater. An anonymous eater ("you") is normal for the first release.
public struct Eater: Hashable, Sendable {
    /// Display name when known; `nil` for "you".
    public let name: String?
    public let restriction: Restriction

    public init(name: String?, restriction: Restriction) {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = trimmed.isEmpty ? nil : trimmed
        } else {
            self.name = nil
        }
        self.restriction = restriction
    }
}

/// The meal context of a decision: who is eating, for how many, with what
/// time and equipment budget. Restrictions are the union of all eaters'
/// (SPEC 2) — computed once, applied everywhere.
public struct MealContext: Sendable {
    public let eaters: [Eater]
    /// Servings to cook. At least 1.
    public let servings: Int
    /// Time budget in seconds, when the user set one.
    public let secondsAvailable: Int?
    /// Equipment the household can use for this meal.
    public let equipment: Set<String>

    public init(eaters: [Eater], servings: Int, secondsAvailable: Int? = nil, equipment: Set<String> = []) throws {
        guard !eaters.isEmpty else {
            throw FLFlowError.validation(target: "MealContext.eaters", reason: "at least one eater is required")
        }
        guard servings >= 1 else {
            throw FLFlowError.validation(target: "MealContext.servings", reason: "must be >= 1 (got \(servings))")
        }
        if let secondsAvailable {
            guard secondsAvailable > 0 else {
                throw FLFlowError.validation(target: "MealContext.secondsAvailable", reason: "must be > 0 when present (got \(secondsAvailable))")
            }
        }
        self.eaters = eaters
        self.servings = servings
        self.secondsAvailable = secondsAvailable
        self.equipment = equipment
    }

    /// The union of all eaters' hard restrictions (SPEC 2). Throwing because
    /// `Restriction` validates at construction; the union of valid
    /// restrictions is valid, so only the empty-literal case can fail.
    public var unionRestriction: Restriction {
        get throws {
            var union = try Restriction()
            for eater in eaters {
                union = union.union(eater.restriction)
            }
            return union
        }
    }
}

// MARK: - Recipe claims port
// Restriction.permits(canonicalName:allergens:dietTags:) documents that the
// caller resolves compound ingredients to their declared allergen set. The
// recipe core (a parallel part) owns that resolution; this is the explicit
// port it feeds. The flows never guess an allergen that was not declared.

/// The declared restriction-relevant properties of one candidate revision.
public struct RecipeClaims: Sendable {
    /// Declared allergens per canonical ingredient name, compound ingredients
    /// already resolved (soy sauce carries wheat, pesto carries nuts).
    public var allergensByIngredient: [String: Set<Allergen>]
    /// Diet tags the revision fails to satisfy (e.g. a beef dish fails
    /// `vegetarian`). The flows refuse candidates failing any eater's diet.
    public var failingDietTags: Set<DietExclusion>
    /// Estimated active time in seconds, when the recipe declares one. Used
    /// only for the time-budget reason, never as a safety claim.
    public var estimatedSeconds: Int?

    public init(allergensByIngredient: [String: Set<Allergen>] = [:], failingDietTags: Set<DietExclusion> = [], estimatedSeconds: Int? = nil) {
        self.allergensByIngredient = allergensByIngredient
        self.failingDietTags = failingDietTags
        self.estimatedSeconds = estimatedSeconds
    }
}

// MARK: - Option shape

/// One required line that needs attention, structured so the UI and the
/// cross-language contract can render "short (with the amount)" honestly.
public struct MissingLine: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Stock exists but falls short; `grams` is the shortfall.
        case short
        /// No quantity evidence on one side. Stays unknown.
        case unknownQuantity
        /// Evidence is stale or never confirmed.
        case needsReconfirming
    }

    public let canonicalName: String
    public let kind: Kind
    /// Shortfall in grams for `.short`; `nil` otherwise.
    public let grams: Double?

    public init(canonicalName: String, kind: Kind, grams: Double? = nil) throws {
        let trimmed = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLFlowError.validation(target: "MissingLine.canonicalName", reason: "must not be empty")
        }
        if kind == .short {
            guard let grams, grams.isFinite, grams > 0 else {
                throw FLFlowError.validation(target: "MissingLine.grams", reason: ".short requires a finite positive shortfall (got \(grams.map { "\( $0)" } ?? "nil"))")
            }
        } else if grams != nil {
            throw FLFlowError.validation(target: "MissingLine.grams", reason: "only .short carries a shortfall amount")
        }
        self.canonicalName = trimmed
        self.kind = kind
        self.grams = grams
    }

    private enum CodingKeys: String, CodingKey { case canonicalName, kind, grams }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            canonicalName: try container.decode(String.self, forKey: .canonicalName),
            kind: try container.decode(Kind.self, forKey: .kind),
            grams: try container.decodeIfPresent(Double.self, forKey: .grams)
        )
    }
}

/// The honest fit line (SPEC 3.2): counts only when they are true, check
/// names otherwise, never a percentage, and never "you have everything"
/// unless every required line is sufficient.
public struct FitLine: Hashable, Codable, Sendable {
    /// Required lines in the summed bill.
    public let requiredCount: Int
    /// Required lines whose state lets tonight proceed.
    public let sufficientCount: Int
    /// Accepted swaps, when the plan substituted (shown as "· N swaps").
    public let swapCount: Int?
    /// Required lines that need attention, in bill order.
    public let checkNames: [String]

    public init(requiredCount: Int, sufficientCount: Int, swapCount: Int? = nil, checkNames: [String]) throws {
        guard requiredCount >= 0, sufficientCount >= 0, sufficientCount <= requiredCount else {
            throw FLFlowError.validation(
                target: "FitLine",
                reason: "sufficientCount must be in 0...\(requiredCount) (got \(sufficientCount))"
            )
        }
        if let swapCount {
            guard swapCount >= 0 else {
                throw FLFlowError.validation(target: "FitLine.swapCount", reason: "must be >= 0")
            }
            guard swapCount <= requiredCount - sufficientCount else {
                throw FLFlowError.validation(
                    target: "FitLine.swapCount",
                    reason: "cannot exceed the uncovered line count"
                )
            }
        }
        // An uncovered line must be named: "check nothing" while short is a lie.
        if sufficientCount + (swapCount ?? 0) < requiredCount && checkNames.isEmpty {
            throw FLFlowError.validation(target: "FitLine.checkNames", reason: "uncovered lines must be named for checking")
        }
        self.requiredCount = requiredCount
        self.sufficientCount = sufficientCount
        self.swapCount = swapCount
        self.checkNames = checkNames
    }

    /// True when every required line is covered — sufficient, or satisfied
    /// through an accepted swap. A swap is a legitimate cover, not a gap.
    public var isReady: Bool {
        requiredCount > 0 && sufficientCount + (swapCount ?? 0) == requiredCount
    }

    /// The display form the SPEC fixes: "9 of 10 · 1 swap" only when nine
    /// lines are sufficient; otherwise "7 recorded · check eggs and oil".
    /// Never a percentage.
    public var display: String {
        if isReady {
            var line = "\(sufficientCount) of \(requiredCount)"
            if let swapCount, swapCount > 0 {
                line += " · \(swapCount) swap\(swapCount == 1 ? "" : "s")"
            }
            return line
        }
        return "\(sufficientCount) recorded · check \(Self.andList(checkNames))"
    }

    /// "eggs", "eggs and oil", "eggs, oil and salt".
    static func andList(_ names: [String]) -> String {
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    private enum CodingKeys: String, CodingKey { case requiredCount, sufficientCount, swapCount, checkNames }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requiredCount: try container.decode(Int.self, forKey: .requiredCount),
            sufficientCount: try container.decode(Int.self, forKey: .sufficientCount),
            swapCount: try container.decodeIfPresent(Int.self, forKey: .swapCount),
            checkNames: try container.decode([String].self, forKey: .checkNames)
        )
    }
}

/// One explainable what-to-cook option: why it was proposed and what is
/// missing — never a bare pick.
public struct DinnerOption: Hashable, Codable, Sendable {
    public let recipeRevision: RecipeKey
    public let title: String
    public let fit: FitLine
    /// Why this option was proposed, in display order (e.g. "all 8 required
    /// lines in stock", "quickest feasible pick").
    public let reasons: [String]
    /// What is missing, structured (SPEC 3.2 states, with amounts).
    public let missing: [MissingLine]
    /// The assumed staples this option leans on, so "assumed" is visible.
    public let assumedStaples: [String]

    public init(
        recipeRevision: RecipeKey,
        title: String,
        fit: FitLine,
        reasons: [String],
        missing: [MissingLine],
        assumedStaples: [String]
    ) throws {
        self.recipeRevision = recipeRevision
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.title.isEmpty else {
            throw FLFlowError.validation(target: "DinnerOption.title", reason: "must not be empty")
        }
        self.fit = fit
        self.reasons = reasons
        self.missing = missing
        self.assumedStaples = assumedStaples
    }

    private enum CodingKeys: String, CodingKey {
        case recipeRevision, title, fit, reasons, missing, assumedStaples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recipeRevision: try container.decode(RecipeKey.self, forKey: .recipeRevision),
            title: try container.decode(String.self, forKey: .title),
            fit: try container.decode(FitLine.self, forKey: .fit),
            reasons: try container.decode([String].self, forKey: .reasons),
            missing: try container.decode([MissingLine].self, forKey: .missing),
            assumedStaples: try container.decode([String].self, forKey: .assumedStaples)
        )
    }
}

/// One shopping-list line distilled from the missing lines.
public struct ShoppingItem: Hashable, Codable, Sendable {
    public let canonicalName: String
    /// The shortfall in grams when the evidence supports a number.
    public let grams: Double?
    /// Why it is on the list (e.g. "short 100 g for the galette").
    public let reason: String

    public init(canonicalName: String, grams: Double?, reason: String) throws {
        let trimmed = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLFlowError.validation(target: "ShoppingItem.canonicalName", reason: "must not be empty")
        }
        self.canonicalName = trimmed
        self.grams = grams
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.reason.isEmpty else {
            throw FLFlowError.validation(target: "ShoppingItem.reason", reason: "must not be empty")
        }
    }

    private enum CodingKeys: String, CodingKey { case canonicalName, grams, reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            canonicalName: try container.decode(String.self, forKey: .canonicalName),
            grams: try container.decodeIfPresent(Double.self, forKey: .grams),
            reason: try container.decode(String.self, forKey: .reason)
        )
    }
}

// MARK: - Tonight states

/// The explicit Tonight states (SPEC 2: "Tonight is a default, not a verdict").
/// Raw values are part of the cross-language fixture contract.
public enum TonightState: String, Codable, Sendable, CaseIterable {
    /// No pantry evidence at all: no scan, camera refused, recognition failed.
    /// Manual entry is first-class.
    case unknownKitchen
    /// A sparse kitchen (one feasible pick): honest "you would need" lists,
    /// nothing claimed ready unless every line really is.
    case sparseKitchen
    /// Nothing passes the hard filters or feasibility bar.
    case nothingFeasible
    /// The normal case: feasible options exist.
    case normal
    /// A cook session is in progress; Tonight leads with the resume card.
    case midCookResume
    /// The user rejected three or more offers; a constraint choice is offered.
    case repeatedRejection
}

/// The constraint choices offered after repeated rejection (SPEC 2): quicker,
/// different main, less effort, pick from a list. Raw values are part of the
/// cross-language fixture contract.
public enum ConstraintChoice: String, Codable, Sendable, CaseIterable {
    case quicker
    case differentMain
    case lessEffort
    case pickFromSaved
}

/// The resume card when a cook session is in progress.
public struct ResumeCard: Hashable, Codable, Sendable {
    public let sessionID: String
    public let recipeTitle: String
    public let stepIndex: Int
    public let stepCount: Int
    /// Labels of timers that are due and unacknowledged.
    public let dueTimerLabels: [String]

    public init(sessionID: String, recipeTitle: String, stepIndex: Int, stepCount: Int, dueTimerLabels: [String]) throws {
        let trimmedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else {
            throw FLFlowError.validation(target: "ResumeCard.sessionID", reason: "must not be empty")
        }
        let trimmedTitle = recipeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw FLFlowError.validation(target: "ResumeCard.recipeTitle", reason: "must not be empty")
        }
        guard stepIndex >= 0, stepCount >= 0, stepIndex <= stepCount else {
            throw FLFlowError.validation(target: "ResumeCard.stepIndex", reason: "must be in 0...\(stepCount) (got \(stepIndex))")
        }
        self.sessionID = trimmedSession
        self.recipeTitle = trimmedTitle
        self.stepIndex = stepIndex
        self.stepCount = stepCount
        self.dueTimerLabels = dueTimerLabels
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, recipeTitle, stepIndex, stepCount, dueTimerLabels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: try container.decode(String.self, forKey: .sessionID),
            recipeTitle: try container.decode(String.self, forKey: .recipeTitle),
            stepIndex: try container.decode(Int.self, forKey: .stepIndex),
            stepCount: try container.decode(Int.self, forKey: .stepCount),
            dueTimerLabels: try container.decode([String].self, forKey: .dueTimerLabels)
        )
    }
}

/// The Tonight proposal: the state, the options (each with its fit line,
/// reasons and missing lines), the shopping list, and the resume/constraint
/// payloads when the state calls for them. Field presence is validated
/// against the state — the same rule FLDomain applies to kind-specific
/// preference fields.
public struct TonightProposal: Hashable, Codable, Sendable {
    public let state: TonightState
    public let generatedAt: Date
    public let servings: Int
    public let eaterCount: Int
    /// Feasible or nearly-feasible options, best first. Empty unless the
    /// state is normal, sparseKitchen or nothingFeasible.
    public let options: [DinnerOption]
    /// What to buy, when lines are missing. Present for sparse and
    /// nothingFeasible; absent otherwise.
    public let shoppingList: [ShoppingItem]?
    /// Present only for midCookResume.
    public let resume: ResumeCard?
    /// Present only for repeatedRejection.
    public let constraintChoices: [ConstraintChoice]?

    public init(
        state: TonightState,
        generatedAt: Date,
        servings: Int,
        eaterCount: Int,
        options: [DinnerOption],
        shoppingList: [ShoppingItem]? = nil,
        resume: ResumeCard? = nil,
        constraintChoices: [ConstraintChoice]? = nil
    ) throws {
        guard servings >= 1 else {
            throw FLFlowError.validation(target: "TonightProposal.servings", reason: "must be >= 1 (got \(servings))")
        }
        guard eaterCount >= 1 else {
            throw FLFlowError.validation(target: "TonightProposal.eaterCount", reason: "must be >= 1 (got \(eaterCount))")
        }
        switch state {
        case .unknownKitchen, .repeatedRejection:
            guard options.isEmpty else {
                throw FLFlowError.validation(target: "TonightProposal.options", reason: "must be empty in state \(state.rawValue)")
            }
        case .normal, .sparseKitchen, .nothingFeasible, .midCookResume:
            break
        }
        if state == .midCookResume {
            guard resume != nil else {
                throw FLFlowError.validation(target: "TonightProposal.resume", reason: "is required in state midCookResume")
            }
        } else {
            guard resume == nil else {
                throw FLFlowError.validation(target: "TonightProposal.resume", reason: "is only allowed in state midCookResume")
            }
        }
        if state == .repeatedRejection {
            guard let choices = constraintChoices, !choices.isEmpty else {
                throw FLFlowError.validation(target: "TonightProposal.constraintChoices", reason: "must be non-empty in state repeatedRejection")
            }
        } else {
            guard constraintChoices == nil else {
                throw FLFlowError.validation(target: "TonightProposal.constraintChoices", reason: "is only allowed in state repeatedRejection")
            }
        }
        if let list = shoppingList, state == .unknownKitchen, !list.isEmpty {
            // An unknown kitchen has nothing to reconcile against: the honest
            // list is the candidates' missing lines, which the UI reads from
            // options. A standalone list would imply stock knowledge.
            throw FLFlowError.validation(target: "TonightProposal.shoppingList", reason: "must be empty in state unknownKitchen")
        }
        self.state = state
        self.generatedAt = generatedAt
        self.servings = servings
        self.eaterCount = eaterCount
        self.options = options
        self.shoppingList = shoppingList
        self.resume = resume
        self.constraintChoices = constraintChoices
    }

    private enum CodingKeys: String, CodingKey {
        case state, generatedAt, servings, eaterCount, options, shoppingList, resume, constraintChoices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            state: try container.decode(TonightState.self, forKey: .state),
            generatedAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .generatedAt),
                target: "TonightProposal.generatedAt"
            ),
            servings: try container.decode(Int.self, forKey: .servings),
            eaterCount: try container.decode(Int.self, forKey: .eaterCount),
            options: try container.decode([DinnerOption].self, forKey: .options),
            shoppingList: try container.decodeIfPresent([ShoppingItem].self, forKey: .shoppingList),
            resume: try container.decodeIfPresent(ResumeCard.self, forKey: .resume),
            constraintChoices: try container.decodeIfPresent([ConstraintChoice].self, forKey: .constraintChoices)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(FLTimestamp.encode(generatedAt), forKey: .generatedAt)
        try container.encode(servings, forKey: .servings)
        try container.encode(eaterCount, forKey: .eaterCount)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(shoppingList, forKey: .shoppingList)
        try container.encodeIfPresent(resume, forKey: .resume)
        try container.encodeIfPresent(constraintChoices, forKey: .constraintChoices)
    }
}

// MARK: - The decision service

/// The deterministic dinner decision (SPEC 4 Plan job, local core): hard
/// filters first, then feasibility with plan reservation, then explainable
/// options. Pure: same inputs, same proposal — byte for byte.
public enum DinnerDecisionService {

    /// The Plan job proposes 3-4 feasible dinners; four is the cap.
    public static let maxOptions = 4

    /// The rejection threshold after which a constraint choice is offered
    /// (SPEC 2: after the third "Something else").
    public static let rejectionThreshold = 3

    /// Evaluates candidates into a Tonight proposal.
    ///
    /// - Parameters:
    ///   - reservations: stock already promised to earlier dinners in this
    ///     plan; the evaluation reserves newly sufficient stock on top.
    ///   - acceptedSwapCounts: per revision, the number of swaps the user
    ///     already accepted (shown as "· N swaps" on the fit line).
    ///   - resume: the in-progress session's card, when Tonight should lead
    ///     with the resume surface instead of new options.
    public static func propose(
        candidates: [(revision: RecipeRevision, claims: RecipeClaims)],
        context: MealContext,
        pantry: PantryView,
        reservations: StockLedger,
        acceptedSwapCounts: [String: Int] = [:],
        resume: ResumeCard? = nil,
        rejectedRevisions: Set<String> = [],
        rejectionCount: Int = 0,
        now: Date? = nil
    ) throws -> TonightProposal {
        let now = now ?? pantry.now
        let restriction = try context.unionRestriction

        // An in-progress session leads Tonight (SPEC 2: mid-cook resume).
        if let resume {
            return try TonightProposal(
                state: .midCookResume,
                generatedAt: now,
                servings: context.servings,
                eaterCount: context.eaters.count,
                options: [],
                resume: resume
            )
        }

        // Repeated rejection: offer a constraint choice, never more of the
        // same. Rejections never become dislikes — nothing here is recorded
        // as a preference event (SPEC 2).
        if rejectionCount >= rejectionThreshold {
            return try TonightProposal(
                state: .repeatedRejection,
                generatedAt: now,
                servings: context.servings,
                eaterCount: context.eaters.count,
                options: [],
                constraintChoices: ConstraintChoice.allCases
            )
        }

        // An empty pantry is an unknown kitchen: say so, propose nothing.
        if pantry.lines.isEmpty {
            return try TonightProposal(
                state: .unknownKitchen,
                generatedAt: now,
                servings: context.servings,
                eaterCount: context.eaters.count,
                options: []
            )
        }

        // Hard filters: restrictions (never weakened, SPEC 3.3) and shipping
        // rights (SPEC 3.5: unknown rights means quarantine). Blocked keys
        // are recorded so a later explanation port can name the reason.
        var blocked: [RecipeKey: String] = [:]
        var passing: [(revision: RecipeRevision, claims: RecipeClaims)] = []
        for candidate in candidates {
            let key = candidate.revision.key
            if rejectedRevisions.contains(key.description) {
                blocked[key] = "rejected by the user just now"  // recorded, never a dislike
                continue
            }
            if candidate.revision.source.license.isQuarantined {
                blocked[key] = "recipe revision is quarantined: rights unknown or forbidden"
                continue
            }
            if let violations = restrictionViolations(revision: candidate.revision, claims: candidate.claims, restriction: restriction), !violations.isEmpty {
                blocked[key] = violations.joined(separator: "; ")
                continue
            }
            passing.append(candidate)
        }

        // Feasibility with plan reservation, in a deterministic order: ready
        // picks first, then more sufficient lines, then fewer required, then
        // the key — so the same inputs always rank the same way.
        var ledger = reservations
        var scored: [(revision: RecipeRevision, result: FeasibilityResult)] = []
        for candidate in passing {
            let result = try FeasibilityEngine.evaluateAndReserve(
                revision: candidate.revision,
                servings: context.servings,
                pantry: pantry,
                ledger: &ledger
            )
            scored.append((candidate.revision, result))
        }
        scored.sort { a, b in
            if a.result.isReady != b.result.isReady { return a.result.isReady }
            if a.result.sufficientCount != b.result.sufficientCount { return a.result.sufficientCount > b.result.sufficientCount }
            if a.result.requiredCount != b.result.requiredCount { return a.result.requiredCount < b.result.requiredCount }
            return a.revision.key.description < b.revision.key.description
        }

        // Time budget: a candidate that cannot fit the budget is still shown
        // honestly when nothing else is feasible, but ready picks that fit
        // rank first.
        var options: [DinnerOption] = []
        for (revision, result) in scored where options.count < maxOptions {
            let swapCount = acceptedSwapCounts[revision.key.description]
            let option = try makeOption(revision: revision, result: result, swapCount: swapCount)
            options.append(option)
        }

        // Shopping list from every option's missing lines, deduplicated by
        // name with the largest known shortfall.
        var shopping: [String: ShoppingItem] = [:]
        for option in options {
            for missing in option.missing {
                switch missing.kind {
                case .unknownQuantity:
                    if shopping[missing.canonicalName] == nil {
                        shopping[missing.canonicalName] = try ShoppingItem(
                            canonicalName: missing.canonicalName,
                            grams: nil,
                            reason: "quantity unknown — check the shelf"
                        )
                    }
                case .needsReconfirming:
                    if shopping[missing.canonicalName] == nil {
                        shopping[missing.canonicalName] = try ShoppingItem(
                            canonicalName: missing.canonicalName,
                            grams: nil,
                            reason: "evidence is stale — reconfirm"
                        )
                    }
                case .short:
                    let shortfall = missing.grams ?? 0
                    if let existing = shopping[missing.canonicalName], let existingGrams = existing.grams {
                        if existingGrams >= shortfall { continue }
                    }
                    shopping[missing.canonicalName] = try ShoppingItem(
                        canonicalName: missing.canonicalName,
                        grams: shortfall,
                        reason: "short \(Self.gramsString(shortfall))"
                    )
                }
            }
        }

        // Nothing survived hard filters or feasibility: the honest state
        // (SPEC 2: never a fake "cook with 2 swaps").
        if options.isEmpty {
            let list = Array(shopping.values).sorted { $0.canonicalName < $1.canonicalName }
            return try TonightProposal(
                state: .nothingFeasible,
                generatedAt: now,
                servings: context.servings,
                eaterCount: context.eaters.count,
                options: [],
                shoppingList: list.isEmpty ? nil : list
            )
        }

        // Sparse is about choice, not shelf size: one feasible pick is a sparse
        // kitchen no matter how many lines are recorded; a real decision
        // between picks is a normal one.
        let state: TonightState = options.count <= 1 ? .sparseKitchen : .normal
        let list = Array(shopping.values).sorted { $0.canonicalName < $1.canonicalName }
        return try TonightProposal(
            state: state,
            generatedAt: now,
            servings: context.servings,
            eaterCount: context.eaters.count,
            options: options,
            shoppingList: list.isEmpty ? nil : list
        )
    }

    /// The specific restriction violations of one candidate against the
    /// union restriction. Empty when the candidate is allowed.
    static func restrictionViolations(
        revision: RecipeRevision,
        claims: RecipeClaims,
        restriction: Restriction
    ) -> [String]? {
        var violations: [String] = []
        for line in revision.requiredIngredientLines {
            let name = line.ingredient.canonicalName
            let allergens = claims.allergensByIngredient[name] ?? []
            if !restriction.permits(canonicalName: name, allergens: allergens) {
                violations.append("'\(name)' conflicts with a hard restriction")
            }
        }
        let failingTags = claims.failingDietTags.intersection(restriction.dietExclusions)
        if !failingTags.isEmpty {
            let tags = failingTags.map(\.rawValue).sorted().joined(separator: ", ")
            violations.append("dish fails diet exclusions: \(tags)")
        }
        return violations
    }

    static func makeOption(revision: RecipeRevision, result: FeasibilityResult, swapCount: Int?) throws -> DinnerOption {
        var reasons: [String] = []
        var missing: [MissingLine] = []
        var staples: [String] = []

        if result.isReady {
            reasons.append("all \(result.requiredCount) required lines are in stock")
            if let swapCount, swapCount > 0 {
                reasons.append("with \(swapCount) accepted swap\(swapCount == 1 ? "" : "s")")
            }
        } else {
            reasons.append("\(result.presentCount) of \(result.requiredCount) required lines are in stock")
        }

        for fit in result.lineFits {
            switch fit.state {
            case .sufficient:
                continue
            case .assumedStaple:
                staples.append(fit.canonicalName)
            case let .short(requested, available):
                missing.append(try MissingLine(
                    canonicalName: fit.canonicalName,
                    kind: .short,
                    grams: requested - available
                ))
            case .quantityUnknown:
                missing.append(try MissingLine(canonicalName: fit.canonicalName, kind: .unknownQuantity))
            case .needsReconfirming:
                missing.append(try MissingLine(canonicalName: fit.canonicalName, kind: .needsReconfirming))
            }
        }

        if !staples.isEmpty {
            reasons.append("assumes \(FitLine.andList(staples.sorted())) from the staple shelf")
        }

        let fit = try FitLine(
            requiredCount: result.requiredCount,
            sufficientCount: result.sufficientCount,
            swapCount: swapCount,
            checkNames: result.checkNames
        )
        return try DinnerOption(
            recipeRevision: revision.key,
            title: revision.title,
            fit: fit,
            reasons: reasons,
            missing: missing.sorted { $0.canonicalName < $1.canonicalName },
            assumedStaples: staples.sorted()
        )
    }

    /// Grams for display: whole grams when close, one decimal otherwise.
    static func gramsString(_ grams: Double) -> String {
        if abs(grams - grams.rounded()) < 0.05 {
            return "\(Int(grams.rounded())) g"
        }
        return String(format: "%.1f g", grams)
    }
}

/// The decision round a user interacts with: shown options, rejections, and
/// the constraint-choice offer after the third rejection. Rejections are
/// never persisted as taste (SPEC 2: "rejections never become dislikes").
public struct TonightSession: Sendable {
    public private(set) var rejectedRevisions: Set<String> = []
    public private(set) var rejectionCount = 0

    public init() {}

    /// Records one "Something else". Pure bookkeeping — no event is emitted.
    public mutating func reject(revision: RecipeKey) {
        rejectedRevisions.insert(revision.description)
        rejectionCount += 1
    }

    /// Whether the next offer must be a constraint choice.
    public var shouldOfferConstraintChoice: Bool {
        rejectionCount >= DinnerDecisionService.rejectionThreshold
    }
}
