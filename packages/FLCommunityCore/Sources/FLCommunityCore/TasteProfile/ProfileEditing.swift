import Foundation
import FLDomain

// MARK: - Taste profile: sentence-based editing
// SPEC 3.3: the taste profile is a page of sentences with evidence, each
// correctable. "Don't ask again" is different from "this is wrong"; the user
// can reopen any sentence; changing your mind never requires a full reset.
//
// Every edit verdict is recorded as a PreferenceEvent(kind: .profileEdit,
// sentenceID, verdict) — FLDomain's ledger type — so the profile page is a
// replay of the ledger, not a mutable row: the current state of a sentence is
// derived from its events, and every event that replaces a prior verdict
// names it (`EventCorrection`, mode .corrects). A mistaken event is removed
// by a retraction (mode .retracts), which restores the state the sentence had
// before. The prompt's "retired" verdict is FLDomain's `.rejected`
// ("this is wrong").

/// One sentence on the taste-profile page.
public struct ProfileSentence: Hashable, Sendable {
    /// SPEC 3.3's three layers. Explicit restrictions are hard filters that
    /// never weaken; stated preferences come from setup and edits; inferred
    /// taste comes from behaviour and expires.
    public enum Layer: String, Codable, Sendable, CaseIterable {
        case explicitRestriction
        case statedPreference
        case inferredTaste
    }

    /// The sentence's current state, derived from its events.
    public enum State: String, Codable, Sendable, CaseIterable {
        /// No verdict yet, or back under consideration after a reopen.
        case open
        case confirmed
        case corrected
        /// "This is wrong" — the sentence is retired from the profile.
        case rejected
        /// A rejected sentence was reopened for a new verdict.
        case reopened
    }

    /// Stable sentence identity. Never empty; at most 128 characters.
    public let sentenceID: String
    /// The sentence as shown, e.g. "You removed coriander 4 of the 5 times
    /// it was in a recipe you cooked". Never empty.
    public let text: String
    public let layer: Layer
    /// The evidence behind the sentence — counted opportunities with
    /// denominators, never "N observations" (SPEC 3.3). Never empty.
    public let evidence: String
    /// The revision the sentence's evidence is anchored to. Every edit event
    /// for this sentence carries it (PreferenceEvent requires a revision).
    public let evidenceRevision: RecipeKey
    /// The state BEFORE `history` is replayed — `open` for a fresh sentence.
    public let state: State

    public init(
        sentenceID: String,
        text: String,
        layer: Layer,
        evidence: String,
        evidenceRevision: RecipeKey,
        state: State = .open
    ) throws {
        let trimmedID = sentenceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw FLDomainError.validation(target: "ProfileSentence.sentenceID", reason: "must not be empty")
        }
        guard trimmedID.count <= 128 else {
            throw FLDomainError.validation(target: "ProfileSentence.sentenceID", reason: "must be at most 128 characters")
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw FLDomainError.validation(target: "ProfileSentence.text", reason: "must not be empty")
        }
        guard trimmedText.count <= 2000 else {
            throw FLDomainError.validation(target: "ProfileSentence.text", reason: "must be at most 2000 characters")
        }
        let trimmedEvidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEvidence.isEmpty else {
            throw FLDomainError.validation(target: "ProfileSentence.evidence", reason: "must not be empty; a sentence without evidence is not shown")
        }
        self.sentenceID = trimmedID
        self.text = trimmedText
        self.layer = layer
        self.evidence = trimmedEvidence
        self.evidenceRevision = evidenceRevision
        self.state = state
    }
}

extension ProfileSentence: Codable {
    private enum CodingKeys: String, CodingKey {
        case sentenceID, text, layer, evidence, evidenceRevision, state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sentenceID: try container.decode(String.self, forKey: .sentenceID),
            text: try container.decode(String.self, forKey: .text),
            layer: try container.decode(Layer.self, forKey: .layer),
            evidence: try container.decode(String.self, forKey: .evidence),
            evidenceRevision: try container.decode(RecipeKey.self, forKey: .evidenceRevision),
            state: try container.decodeIfPresent(State.self, forKey: .state) ?? .open
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sentenceID, forKey: .sentenceID)
        try container.encode(text, forKey: .text)
        try container.encode(layer, forKey: .layer)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(evidenceRevision, forKey: .evidenceRevision)
        try container.encode(state, forKey: .state)
    }
}

/// The result of one recorded edit: the event to append to the ledger, and
/// the sentence's state after it.
public struct ProfileEditRecording: Hashable, Sendable {
    public let event: PreferenceEvent
    public let sentence: ProfileSentence
}

/// Records taste-profile edits as `profileEdit` PreferenceEvents.
///
/// All functions are pure: the caller supplies the event ID, the timestamp
/// and the sentence's event history; nothing here reads a clock or a store.
/// The history is validated strictly — every event must be a `profileEdit`
/// for this sentence's ID and anchor revision, IDs must be unique, and the
/// supersession chain must be contiguous — so a replay of the same ledger
/// always derives the same state.
public enum ProfileEditRecorder {
    /// Record a verdict on a sentence.
    ///
    /// Transitions (frozen by tests):
    /// - from a live state (`open`, `confirmed`, `corrected`, `reopened`)
    ///   any verdict applies except `.reopened`;
    /// - from `.rejected` only `.reopened` applies — a retired sentence must
    ///   be reopened before a new verdict ("the user can reopen any
    ///   sentence", SPEC 3.3).
    ///
    /// The new event supersedes the sentence's current effective event
    /// (`.corrects`), or starts the chain when there is none.
    public static func record(
        verdict: ProfileSentenceVerdict,
        sentence: ProfileSentence,
        eventID: String,
        at timestamp: Date,
        history: [PreferenceEvent],
        source: PreferenceEventSource = .userExplicit
    ) throws -> ProfileEditRecording {
        let replay = try replayState(of: sentence, history: history)
        switch (replay.state, verdict) {
        case (.rejected, .reopened):
            break
        case (.rejected, _):
            throw FLDomainError.validation(
                target: "ProfileEditRecorder.verdict",
                reason: "sentence \(sentence.sentenceID) is rejected ('this is wrong'); reopen it before a new verdict"
            )
        case (_, .reopened):
            throw FLDomainError.validation(
                target: "ProfileEditRecorder.verdict",
                reason: "sentence \(sentence.sentenceID) is not rejected, so it cannot be reopened"
            )
        case (_, _):
            break
        }

        let event = try PreferenceEvent(
            id: eventID,
            kind: .profileEdit,
            timestamp: timestamp,
            recipeRevision: sentence.evidenceRevision,
            source: source,
            supersedes: replay.effectiveEvent.map { EventCorrection(priorEventID: $0.id, mode: .corrects) },
            sentenceID: sentence.sentenceID,
            verdict: verdict
        )
        let newState = Self.state(for: verdict)
        let newSentence = try ProfileSentence(
            sentenceID: sentence.sentenceID,
            text: sentence.text,
            layer: sentence.layer,
            evidence: sentence.evidence,
            evidenceRevision: sentence.evidenceRevision,
            state: newState
        )
        return ProfileEditRecording(event: event, sentence: newSentence)
    }

    /// Retract a mistaken event — one recorded in error, e.g. against the
    /// wrong sentence. Only the current effective event can be retracted.
    /// The retraction event restates the retracted event's verdict because
    /// FLDomain requires a verdict on every profileEdit; its supersession
    /// mode `.retracts` is what gives it meaning: the prior event loses all
    /// effect and the sentence reverts to the state before it.
    public static func retract(
        eventIDToRetract: String,
        eventID: String,
        sentence: ProfileSentence,
        at timestamp: Date,
        history: [PreferenceEvent],
        source: PreferenceEventSource = .userExplicit
    ) throws -> ProfileEditRecording {
        let replay = try replayState(of: sentence, history: history)
        guard let effective = replay.effectiveEvent else {
            throw FLDomainError.validation(
                target: "ProfileEditRecorder.retract",
                reason: "sentence \(sentence.sentenceID) has no effective event to retract"
            )
        }
        guard effective.id.rawValue == eventIDToRetract else {
            throw FLDomainError.validation(
                target: "ProfileEditRecorder.retract",
                reason: "only the current effective event can be retracted; effective is \(effective.id), requested \(eventIDToRetract)"
            )
        }
        let event = try PreferenceEvent(
            id: eventID,
            kind: .profileEdit,
            timestamp: timestamp,
            recipeRevision: sentence.evidenceRevision,
            source: source,
            supersedes: EventCorrection(priorEventID: effective.id, mode: .retracts),
            sentenceID: sentence.sentenceID,
            verdict: effective.verdict
        )
        // State after removal: the state of whatever remains effective.
        let stateAfter = try state(of: sentence, history: history + [event])
        let newSentence = try ProfileSentence(
            sentenceID: sentence.sentenceID,
            text: sentence.text,
            layer: sentence.layer,
            evidence: sentence.evidence,
            evidenceRevision: sentence.evidenceRevision,
            state: stateAfter
        )
        return ProfileEditRecording(event: event, sentence: newSentence)
    }

    private static func state(for verdict: ProfileSentenceVerdict) -> ProfileSentence.State {
        switch verdict {
        case .confirmed: return .confirmed
        case .corrected: return .corrected
        case .rejected: return .rejected
        case .reopened: return .reopened
        }
    }

    private static func state(of sentence: ProfileSentence, history: [PreferenceEvent]) throws -> ProfileSentence.State {
        try replayState(of: sentence, history: history).state
    }

    /// The sentence's state and effective event after replaying `history`.
    ///
    /// Replay rules: the chain starts with the history's first event (which
    /// must carry no supersession); each later event must supersede the
    /// current effective event — `.corrects` replaces it, `.retracts` removes
    /// it and restores the state underneath; a `.retracts` event itself adds
    /// no verdict to the state.
    public static func replayState(
        of sentence: ProfileSentence,
        history: [PreferenceEvent]
    ) throws -> (state: ProfileSentence.State, effectiveEvent: PreferenceEvent?) {
        // Strict ledger validation for this sentence.
        var seenIDs = Set<PreferenceEventID>()
        for event in history {
            guard event.kind == .profileEdit else {
                throw FLDomainError.validation(
                    target: "ProfileEditRecorder.history",
                    reason: "event \(event.id) is \(event.kind.rawValue), not profileEdit"
                )
            }
            guard event.sentenceID == sentence.sentenceID else {
                throw FLDomainError.validation(
                    target: "ProfileEditRecorder.history",
                    reason: "event \(event.id) records sentence \(event.sentenceID ?? "nil"), not \(sentence.sentenceID)"
                )
            }
            guard event.recipeRevision == sentence.evidenceRevision else {
                throw FLDomainError.validation(
                    target: "ProfileEditRecorder.history",
                    reason: "event \(event.id) anchors to \(event.recipeRevision), not \(sentence.evidenceRevision)"
                )
            }
            guard seenIDs.insert(event.id).inserted else {
                throw FLDomainError.validation(
                    target: "ProfileEditRecorder.history",
                    reason: "duplicate event id \(event.id)"
                )
            }
        }

        var chain: [PreferenceEvent] = []
        for event in history {
            if let supersedes = event.supersedes {
                switch supersedes.mode {
                case .corrects:
                    guard let top = chain.last, top.id == supersedes.priorEventID else {
                        throw FLDomainError.validation(
                            target: "ProfileEditRecorder.history",
                            reason: "event \(event.id) supersedes \(supersedes.priorEventID), but the effective event is \(chain.last?.id.description ?? "none")"
                        )
                    }
                    // Push, don't replace: supersession is a stack. If the corrected
                    // event is later retracted, the state it corrected becomes
                    // effective again underneath.
                    chain.append(event)
                case .retracts:
                    guard let top = chain.last, top.id == supersedes.priorEventID else {
                        throw FLDomainError.validation(
                            target: "ProfileEditRecorder.history",
                            reason: "event \(event.id) retracts \(supersedes.priorEventID), but the effective event is \(chain.last?.id.description ?? "none")"
                        )
                    }
                    chain.removeLast()
                }
            } else {
                guard chain.isEmpty else {
                    throw FLDomainError.validation(
                        target: "ProfileEditRecorder.history",
                        reason: "event \(event.id) starts a new chain while \(chain.last!.id) is still effective"
                    )
                }
                chain.append(event)
            }
        }
        if let top = chain.last, let verdict = top.verdict {
            return (Self.state(for: verdict), top)
        }
        return (sentence.state, chain.last)
    }
}
