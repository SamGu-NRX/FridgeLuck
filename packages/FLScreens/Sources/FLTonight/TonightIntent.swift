// FLTonight — typed intents and the reducer.
//
// Intents are what the screen's controls send. Two kinds:
//
// - Presentation-logic intents: the reducer applies them here (rejection
//   bookkeeping, the constraint choice, the taste question, servings) so
//   the rules are Linux-testable.
// - Navigation/effect intents: routed to the host through the view's send
//   closure; the reducer returns state unchanged for them, because the
//   outcome (a new pick, a pushed recipe, a scan flow) arrives as new
//   state from the host, not from this layer.

/// The constraint choices offered after the third "Something else"
/// (SPEC 2): quicker, different main, less effort, or pick from a list.
/// Rejections never become dislikes — choosing a constraint filters the
/// next pick; it never writes a preference.
public enum TonightConstraint: String, Equatable, Sendable, CaseIterable {
    case quicker
    case differentMain
    case lessEffort
    case pickFromList
}

/// Everything the Tonight screen can send.
public enum TonightIntent: Equatable, Sendable {

    // Presentation logic (reducer-owned)

    /// The primary action was pressed; the host confirms and starts the
    /// cook. Carries the state swap count honesty through the state's
    /// `primaryActionStatesSwaps`.
    case cookThis
    /// "Something else": rejections are counted, never scored as dislikes;
    /// after the third press the constraint choice is offered.
    case somethingElse
    /// A constraint was chosen from the offered list.
    case chooseConstraint(TonightConstraint)
    /// The taste question ("Stop suggesting it?") was answered. Either
    /// answer dismisses the question here; no taste field changes.
    case answerTasteQuestion(questionID: String, stop: Bool)
    /// Servings changed from the context control. Clamped to 1...12.
    case setServings(Int)
    /// The late lines (why, table) arrived after a swap.
    case lateLinesArrived

    // Navigation / effects (host-routed; reducer is identity)

    /// Always available (SPEC 2): the user can choose tomorrow; there is
    /// no clock cutoff.
    case chooseTomorrow
    /// Scan entry — the search-role tab's fallback so scan is always
    /// reachable as a prominent action.
    case scanKitchen
    /// Manual entry is first-class, including from an unknown kitchen.
    case enterManually
    case resumeCook
    case openWhy
    case openAlternative(recipeID: String)
    case openUseSoon(itemID: String)
    case openProfileSentence(sentenceID: String)
    case shoppingList
    case pickFromSaved
}

/// The reducer: pure, total over intents, and the only place presentation
/// logic lives. `TonightViewState.apply(_:)` is the convenience views use.
public enum TonightReducer {

    public static func reduced(_ state: TonightViewState, by intent: TonightIntent) -> TonightViewState {
        var next = state
        switch intent {

        case .somethingElse:
            next.rejectionCount += 1
            // "After the third 'Something else', offer a constraint choice."
            next.constraintsOffered = next.rejectionCount % 3 == 0
            // Rejections never become dislikes: nothing else changes, and
            // no taste field exists on this state to receive one.

        case .chooseConstraint:
            // The choice filters the host's next pick; the offer closes.
            next.constraintsOffered = false

        case .answerTasteQuestion:
            // Asked once, never repeated. Either answer dismisses the
            // question; the state records no preference either way.
            next.tasteQuestion = nil

        case .setServings(let servings):
            let clamped = min(max(servings, 1), 12)
            next.content = next.content.updatingPick { pick in
                pick.meta.servings = clamped
            }

        case .lateLinesArrived:
            next.lateLinesLoading = false

        // Navigation and effects: the host owns the outcome.
        case .cookThis, .chooseTomorrow, .scanKitchen, .enterManually,
             .resumeCook, .openWhy, .openAlternative, .openUseSoon,
             .openProfileSentence, .shoppingList, .pickFromSaved:
            break
        }
        return next
    }
}

extension TonightViewState.Content {

    /// Applies `change` to the carried pick, preserving the content case —
    /// a servings edit must never morph a sparse kitchen into a full pick.
    func updatingPick(_ change: (inout TonightViewState.Pick) -> Void) -> TonightViewState.Content {
        switch self {
        case .unknownKitchen(let reason, var example):
            if var pick = example { change(&pick); example = pick }
            return .unknownKitchen(reason: reason, example: example)
        case .pick(var pick):
            change(&pick)
            return .pick(pick)
        case .sparse(var pick, let youdNeed):
            change(&pick)
            return .sparse(pick: pick, youdNeed: youdNeed)
        case .nothingFeasible(var pick):
            change(&pick)
            return .nothingFeasible(pick: pick)
        }
    }
}

extension TonightViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: TonightIntent) {
        self = TonightReducer.reduced(self, by: intent)
    }
}
