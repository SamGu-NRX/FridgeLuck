import Foundation

/// The folded model state. Always the pure result of folding the event log;
/// nothing mutates it outside `fold`.
///
/// Determinism contract: folding the same events (in any order) yields equal
/// state. Derived from: sort by event timestamp, tie-break by event id;
/// duplicate ids collapse to their first occurrence in that order; a
/// correction applies to the event it amends wherever that event sits in the
/// order.
public struct EngineState: Equatable, Sendable {
    public var seenEventIDs: Set<EventID>
    public var eventCount: Int
    public var firstEventAt: Instant?
    public var lastEventAt: Instant?
    /// Events dropped with a reason (unknown correction target, household
    /// event with no eater yet...). Deterministic: fold order.
    public var diagnostics: [Diagnostic]
    /// Explicit layer scoped to the whole household (nil-eater edits).
    public var household: ExplicitLayer
    /// Per-eater state, including each eater's explicit layer.
    public var eaters: [EaterID: EaterState]

    public init() {
        self.seenEventIDs = []
        self.eventCount = 0
        self.firstEventAt = nil
        self.lastEventAt = nil
        self.diagnostics = []
        self.household = ExplicitLayer()
        self.eaters = [:]
    }

    public struct Diagnostic: Equatable, Sendable {
        public let eventID: EventID
        public let reason: String
    }
}

/// Restrictions, stated preferences and the never-suggest list, plus the
/// per-sentence ledger (confirmed / rejected / corrected) that the profile
/// page renders.
public struct ExplicitLayer: Equatable, Sendable {
    /// Fold order; upsert on re-set.
    public var restrictions: [Restriction]
    public var neverSuggest: [IngredientID: NeverSuggestRecord]
    public var stated: [FeatureKey: StatedPreference]

    public init() {
        self.restrictions = []
        self.neverSuggest = [:]
        self.stated = [:]
    }

    public struct NeverSuggestRecord: Equatable, Sendable {
        public let addedAt: Instant
    }

    public struct StatedPreference: Equatable, Sendable {
        public let polarity: Polarity
        public let addedAt: Instant
    }
}

/// One eater's state.
public struct EaterState: Equatable, Sendable {
    public var explicit: ExplicitLayer
    /// Raw interaction history per recipe — the source of sentence counts,
    /// denominators and recency. Model updates (M2) read the same records.
    public var recipeHistory: [RecipeID: RecipeHistory]
    /// Total cook events folded for this eater (denominator for "n of m").
    public var totalCooks: Int

    public init() {
        self.explicit = ExplicitLayer()
        self.recipeHistory = [:]
        self.totalCooks = 0
    }
}

/// Everything folded about one recipe for one eater.
public struct RecipeHistory: Equatable, Sendable {
    public var views: Int
    public var opens: Int
    public var saves: Int
    public var skips: [SkipRecord]
    public var cooks: [CookRecord]
    public var servingsEdits: [ServingsEdit]
    public var substitutions: [SubstitutionRecord]
    public var feedback: [FeedbackRecord]

    public init() {
        self.views = 0
        self.opens = 0
        self.saves = 0
        self.skips = []
        self.cooks = []
        self.servingsEdits = []
        self.substitutions = []
        self.feedback = []
    }

    public struct SkipRecord: Equatable, Sendable {
        public let at: Instant
        public let reason: SkipReason
    }

    public struct CookRecord: Equatable, Sendable {
        public let at: Instant
        public let rating: Rating?
        public let wouldMakeAgain: Bool?
    }

    public struct ServingsEdit: Equatable, Sendable {
        public let at: Instant
        public let from: Int
        public let to: Int
    }

    public struct SubstitutionRecord: Equatable, Sendable {
        public let at: Instant
        public let from: IngredientID
        public let to: IngredientID?
        public let mode: SubstitutionMode?
    }

    public struct FeedbackRecord: Equatable, Sendable {
        public let at: Instant
        public let feedback: LeChefFeedback
    }
}

// MARK: - Fold

public enum Fold {
    /// Folds events into state. Total: dangling corrections land in
    /// `state.diagnostics`; it never throws.
    public static func apply(_ events: [TasteEvent], to initial: EngineState = EngineState())
        -> EngineState
    {
        var state = initial
        // Bookkeeping over every event: canonical order, duplicates are
        // no-ops, voided events stay seen (idempotency, transparency).
        let ordered = events.sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id < rhs.id
        }
        for event in ordered {
            guard !state.seenEventIDs.contains(event.id) else { continue }
            state.seenEventIDs.insert(event.id)
            state.eventCount += 1
            state.firstEventAt = state.firstEventAt ?? event.at
            state.lastEventAt = event.at
        }

        let (stream, diagnostics) = effectiveStream(events)
        state.diagnostics.append(contentsOf: diagnostics)
        for event in stream {
            applyBehavioral(event, to: &state)
            applyExplicit(event, to: &state)
        }
        return state
    }

    /// The effective behavioral stream: canonical (timestamp, id) order,
    /// duplicate ids collapsed to their first occurrence, voided events and
    /// voided corrections dropped, surviving corrections' resolutions
    /// applied to their targets. Shared by the state fold and the model
    /// fold (`TasteModel`) so corrections behave identically in both.
    /// Returns dangling-correction diagnostics alongside the stream.
    public static func effectiveStream(_ events: [TasteEvent]) -> (
        stream: [TasteEvent], diagnostics: [EngineState.Diagnostic]
    ) {
        let ordered = events.sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id < rhs.id
        }

        var knownIDs = Set<EventID>()
        for event in ordered { knownIDs.insert(event.id) }

        // Map amended id -> resolutions in fold order. A correction applies
        // whether it precedes or follows its target in the caller's input
        // order. A correction that is itself voided contributes nothing.
        //
        // Void chains resolve by fixpoint: voiding a void revives whatever
        // that void removed, so changing your mind never needs a reset.
        // Cycles (two voids targeting each other) resolve deterministically
        // in canonical event order.
        var voidLinks: [(id: EventID, target: EventID)] = []
        for event in ordered {
            if case .correction(let amends, let resolution) = event.kind,
                resolution == .void, knownIDs.contains(amends), amends != event.id
            {
                voidLinks.append((event.id, amends))
            }
        }
        var activeVoids = Set(voidLinks.map(\.id))
        var changed = true
        while changed {
            changed = false
            for link in voidLinks where activeVoids.contains(link.id) {
                let targetedByActiveVoid = voidLinks.contains {
                    $0.target == link.id && activeVoids.contains($0.id)
                }
                if targetedByActiveVoid {
                    activeVoids.remove(link.id)
                    changed = true
                }
            }
        }
        var voidedCorrections = Set<EventID>()
        for link in voidLinks where activeVoids.contains(link.id) {
            voidedCorrections.insert(link.target)
        }
        var amendments: [EventID: [(at: Instant, id: EventID, resolution: CorrectionResolution)]] =
            [:]
        var diagnostics: [EngineState.Diagnostic] = []
        for event in ordered {
            guard case .correction(let amends, let resolution) = event.kind else { continue }
            guard knownIDs.contains(amends), amends != event.id else {
                diagnostics.append(
                    .init(eventID: event.id, reason: "correction target missing"))
                continue
            }
            guard !voidedCorrections.contains(event.id) else { continue }
            amendments[amends, default: []].append((event.at, event.id, resolution))
        }

        var seen = Set<EventID>()
        var stream: [TasteEvent] = []
        for event in ordered {
            guard !seen.contains(event.id) else { continue }
            seen.insert(event.id)
            guard !voidedCorrections.contains(event.id) else { continue }
            let resolutions = (amendments[event.id] ?? []).sorted(by: {
                if $0.at != $1.at { return $0.at < $1.at }
                return $0.id < $1.id
            })
            if resolutions.contains(where: { $0.resolution == .void }) {
                // Voided: contributes nothing further.
                continue
            }
            var effectiveEvent = event
            for (_, _, resolution) in resolutions {
                effectiveEvent = Self.applying(resolution, to: effectiveEvent)
            }
            stream.append(effectiveEvent)
        }
        return (stream, diagnostics)
    }

    private static func applying(_ resolution: CorrectionResolution, to event: TasteEvent)
        -> TasteEvent
    {
        switch resolution {
        case .void:
            return event  // handled by the caller
        case .setRating(let rating):
            if case .cooked(let recipe, _, let wma) = event.kind {
                return TasteEvent(
                    id: event.id, at: event.at, eater: event.eater, exposure: event.exposure,
                    kind: .cooked(recipe: recipe, rating: rating, wouldMakeAgain: wma))
            }
            return event
        case .setWouldMakeAgain(let wma):
            if case .cooked(let recipe, let rating, _) = event.kind {
                return TasteEvent(
                    id: event.id, at: event.at, eater: event.eater, exposure: event.exposure,
                    kind: .cooked(recipe: recipe, rating: rating, wouldMakeAgain: wma))
            }
            return event
        case .reattribute(let eater):
            return TasteEvent(
                id: event.id, at: event.at, eater: eater, exposure: event.exposure,
                kind: event.kind)
        }
    }

    /// Behavioural history for sentence denominators. Model updates (M2)
    /// read the same records.
    private static func applyBehavioral(_ event: TasteEvent, to state: inout EngineState) {
        func record(_ recipeID: RecipeID, _ mutate: (inout RecipeHistory) -> Void) {
            switch event.eater {
            case .some(let eater):
                var eaterState = state.eaters[eater] ?? EaterState()
                var history = eaterState.recipeHistory[recipeID] ?? RecipeHistory()
                mutate(&history)
                eaterState.recipeHistory[recipeID] = history
                state.eaters[eater] = eaterState
            case .none:
                // Household event: recorded on every eater known at this
                // point. Before any eater is known there is nothing to attach
                // to; drop with a diagnostic.
                let known = state.eaters.keys.sorted()
                if known.isEmpty {
                    state.diagnostics.append(
                        .init(eventID: event.id, reason: "no eater for household event"))
                    return
                }
                for eater in known {
                    var eaterState = state.eaters[eater] ?? EaterState()
                    var history = eaterState.recipeHistory[recipeID] ?? RecipeHistory()
                    mutate(&history)
                    eaterState.recipeHistory[recipeID] = history
                    state.eaters[eater] = eaterState
                }
            }
        }

        switch event.kind {
        case .viewed(let recipe):
            record(recipe) { $0.views += 1 }
        case .opened(let recipe):
            record(recipe) { $0.opens += 1 }
        case .saved(let recipe):
            record(recipe) { $0.saves += 1 }
        case .cooked(let recipe, let rating, let wouldMakeAgain):
            record(recipe) {
                $0.cooks.append(
                    .init(at: event.at, rating: rating, wouldMakeAgain: wouldMakeAgain))
            }
            bumpCookCount(for: event, in: &state)
        case .skipped(let recipe, let reason):
            record(recipe) { $0.skips.append(.init(at: event.at, reason: reason)) }
        case .substituted(let recipe, let from, let to, let mode):
            record(recipe) {
                $0.substitutions.append(.init(at: event.at, from: from, to: to, mode: mode))
            }
        case .editedServings(let recipe, let from, let to):
            record(recipe) { $0.servingsEdits.append(.init(at: event.at, from: from, to: to)) }
        case .leChefFeedback(let recipe, let feedback):
            record(recipe) { $0.feedback.append(.init(at: event.at, feedback: feedback)) }
        case .profileEdit, .correction:
            break
        }
    }

    private static func bumpCookCount(for event: TasteEvent, in state: inout EngineState) {
        switch event.eater {
        case .some(let eater):
            state.eaters[eater]?.totalCooks += 1
        case .none:
            for eater in state.eaters.keys.sorted() {
                state.eaters[eater]?.totalCooks += 1
            }
        }
    }

    /// Explicit-layer writes. Only `profileEdit` events write these layers;
    /// that is why edits are predictable and reversible.
    private static func applyExplicit(_ event: TasteEvent, to state: inout EngineState) {
        guard case .profileEdit(let op) = event.kind else { return }
        switch event.eater {
        case .some(let eater):
            var eaterState = state.eaters[eater] ?? EaterState()
            applyToLayer(op, at: event.at, into: &eaterState.explicit)
            state.eaters[eater] = eaterState
        case .none:
            applyToLayer(op, at: event.at, into: &state.household)
        }
    }

    private static func applyToLayer(
        _ op: ProfileEditOp, at instant: Instant, into layer: inout ExplicitLayer
    ) {
        switch op {
        case .setRestriction(let restriction):
            layer.restrictions.removeAll {
                $0.kind == restriction.kind && $0.target == restriction.target
            }
            layer.restrictions.append(restriction)
        case .clearRestriction(let key):
            layer.restrictions.removeAll { $0.kind == key.kind && $0.target == key.target }
        case .setPreference(let feature, let polarity):
            layer.stated[feature] = .init(polarity: polarity, addedAt: instant)
        case .clearPreference(let feature):
            layer.stated.removeValue(forKey: feature)
        case .setNeverSuggest(let ingredient):
            layer.neverSuggest[ingredient] = .init(addedAt: instant)
        case .clearNeverSuggest(let ingredient):
            layer.neverSuggest.removeValue(forKey: ingredient)
        }
    }
}
