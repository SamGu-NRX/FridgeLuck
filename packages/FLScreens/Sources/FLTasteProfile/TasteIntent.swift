// FLTasteProfile — typed intents and the reducer.
//
// Same split as every screen module: presentation-logic intents are
// applied by the reducer here (Linux-testable); navigation and device
// effects are routed to the host and change nothing in state.
//
// The ledger's cardinal rule: nothing is deleted by judgement. Wrong
// excludes and keeps; forget holds a receipt with undo; forget-all asks
// once and preserves restrictions. Only the host's store delete
// (outside this screen) truly removes anything.

import Foundation

/// Everything the taste ledger can send.
public enum TasteIntent: Equatable, Sendable {

    // Judgements (reducer-owned; the store write is the host's)

    /// Right or Wrong on a sentence. Right confirms (the app acts on the
    /// pattern), Wrong rejects (excluded and kept). Judging again
    /// switches; undo restores learning.
    case judge(sentenceID: String, right: Bool)
    /// Undo a confirmed or rejected sentence back to learning.
    case undoJudgement(sentenceID: String)
    /// "Don't ask again" — stops future prompts about this pattern; the
    /// record and its status stay. A different control from Wrong.
    case dontAskAgain(sentenceID: String)
    /// An offer row's answers: Suggest some confirms the offer;
    /// Not interested declines it for now (the Never suggest door
    /// remains).
    case answerOffer(sentenceID: String, suggest: Bool)
    /// The offer's permanent door: never suggest this again. The record
    /// stays; prompts stop.
    case neverSuggest(sentenceID: String)

    // Memory (reducer-owned)

    /// "Forget" on a remembered note: it leaves the list with a visible
    /// receipt; undo restores it in place.
    case forgetMemory(id: String)
    /// Undo the last forget — the note returns at its original place.
    case undoForget

    // Forget everything (reducer-owned state, host-persisted)

    /// The error-red footer button: asks once, with the count.
    case askForgetAll
    case cancelForgetAll
    /// The confirmation's Yes: sentences and memories go; explicit
    /// restrictions survive. The host persists the wipe.
    case forgetEverything

    // Restrictions (reducer-owned validation)

    /// Add a restriction by name. Empty/whitespace names and
    /// case-insensitive duplicates are refused.
    case addRestriction(name: String)
    /// Remove an unlocked restriction. Locked (setup-set) ones are
    /// refused — they are edited in setup, never weakened here.
    case removeRestriction(id: String)

    // Save / effects (host-routed)

    /// The host persists pending edits (usually immediately after each
    /// edit; the flag survives until the host reports).
    case saveEdits
    /// The host persisted; the unsaved flag clears.
    case editsSaved
    /// The host failed to persist; the edits are kept, the error shows.
    case editsFailed
    /// "Export everything I know about you" — writes a readable file to
    /// Files. The only way taste data leaves the device.
    case exportTaste
    /// "Edit" on the setup summary — routes to setup.
    case editSetup
}

/// The reducer: pure, total over intents.
public enum TasteReducer {

    public static func reduced(_ state: TasteViewState, by intent: TasteIntent) -> TasteViewState {
        var next = state
        switch intent {

        // MARK: Judgements

        case .judge(let id, let right):
            guard let index = next.sentences.firstIndex(where: { $0.id == id }) else { break }
            next.sentences[index].status = right ? .confirmed : .rejected
            next.hasUnsavedChanges = true
            next.saveFailed = false

        case .undoJudgement(let id):
            guard let index = next.sentences.firstIndex(where: { $0.id == id }) else { break }
            // Restores exactly: status and the confirmation line clear.
            next.sentences[index].status = .learning
            next.sentences[index].confirmationLine = nil
            next.hasUnsavedChanges = true
            next.saveFailed = false

        case .dontAskAgain(let id):
            guard let index = next.sentences.firstIndex(where: { $0.id == id }) else { break }
            // Stops prompts; the record and its status stay untouched.
            next.sentences[index].promptSuppressed = true
            next.hasUnsavedChanges = true
            next.saveFailed = false

        case .answerOffer(let id, let suggest):
            guard let index = next.sentences.firstIndex(where: { $0.id == id }) else { break }
            guard next.sentences[index].kind == .offer else { break }
            if suggest {
                next.sentences[index].status = .confirmed
            } else {
                // The polite no: declined for now; Never suggest remains.
                next.sentences[index].offerDeclined = true
            }
            next.hasUnsavedChanges = true
            next.saveFailed = false

        case .neverSuggest(let id):
            guard let index = next.sentences.firstIndex(where: { $0.id == id }) else { break }
            next.sentences[index].promptSuppressed = true
            next.sentences[index].offerDeclined = true
            next.hasUnsavedChanges = true
            next.saveFailed = false

        // MARK: Memory

        case .forgetMemory(let id):
            guard let index = next.memories.firstIndex(where: { $0.id == id }) else { break }
            let memory = next.memories.remove(at: index)
            next.lastForgotten = TasteViewState.ForgottenMemory(memory: memory, previousIndex: index)
            next.hasUnsavedChanges = true
            next.saveFailed = false

        case .undoForget:
            guard let forgotten = next.lastForgotten else { break }
            // Restore in place, clamped to the list's current bounds.
            let index = min(forgotten.previousIndex, next.memories.count)
            next.memories.insert(forgotten.memory, at: index)
            next.lastForgotten = nil
            next.hasUnsavedChanges = true
            next.saveFailed = false

        // MARK: Forget everything

        case .askForgetAll:
            guard next.forgettableCount > 0 else { break }
            next.isConfirmingForgetAll = true

        case .cancelForgetAll:
            next.isConfirmingForgetAll = false

        case .forgetEverything:
            guard next.isConfirmingForgetAll else { break }
            next.isConfirmingForgetAll = false
            // Sentences and memories go; explicit restrictions survive.
            next.sentences = []
            next.memories = []
            next.lastForgotten = nil
            next.isNewUser = false
            next.newUserLine = nil
            next.hasUnsavedChanges = true
            next.saveFailed = false

        // MARK: Restrictions

        case .addRestriction(let name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }
            guard !next.hasRestriction(named: trimmed) else { break }
            next.restrictions.append(
                TasteViewState.Restriction(id: "restriction-" + String(next.restrictions.count + 1), name: trimmed)
            )
            next.hasUnsavedChanges = true
            next.saveFailed = false

        case .removeRestriction(let id):
            guard let index = next.restrictions.firstIndex(where: { $0.id == id }) else { break }
            // Setup-set restrictions are never weakened here.
            guard !next.restrictions[index].isLocked else { break }
            next.restrictions.remove(at: index)
            next.hasUnsavedChanges = true
            next.saveFailed = false

        // MARK: Save / effects

        case .saveEdits:
            break

        case .editsSaved:
            next.hasUnsavedChanges = false
            next.saveFailed = false

        case .editsFailed:
            // The edits stay; the error shows until the next save.
            next.saveFailed = true

        case .exportTaste, .editSetup:
            break
        }
        return next
    }
}

extension TasteViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: TasteIntent) {
        self = TasteReducer.reduced(self, by: intent)
    }
}
