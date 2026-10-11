// FLLeChef — typed intents and the reducer.
//
// Two kinds, as everywhere in FLScreens:
//
// - Session-logic intents: the reducer applies them (the stage machine,
//   step engine, timer lifecycle, proposal approval semantics, the
//   transcript toggle, the record save) so the rules are
//   Linux-testable.
// - Host-effect intents: routed to the host through the view's send
//   closure; the reducer returns state unchanged, because the outcome
//   (the camera frame, the look's result, the assistant's answer, the
//   persisted write) arrives as new state from the host.
//
// The contract lines the reducer enforces:
//
// - A mutation proposal is applied ONLY by `.approveProposal` — an
//   explicit approval action. Delivery never applies one; a voice
//   command never reaches one (the five-word grammar maps to the coach
//   surface only).
// - Timers are phone-controlled: set, pause and complete are local
//   state-machine operations. A timer is acknowledged only after the
//   machine created it.
// - The record save is explicit. A voice-drafted note is a draft until
//   the user confirms; a transcript alone never saves or shares.
// - Steps and timers progress with zero connectivity: nothing in the
//   reducer reads the link.

import Foundation

/// Everything the LeChef session can send.
public enum LeChefIntent: Equatable, Sendable {

    // Entry / stage machine (reducer-owned)

    /// Enter cook mode from a recipe or Tonight's pick. The host hands
    /// over the recipe and its clock. Ignored unless idle.
    case enter(recipe: LeChefViewState.CookRecipe, at: TimeInterval)
    /// "Leave cook" — the session parks (state persists for resume) and
    /// the host dismisses the presentation.
    case leaveSession
    /// Park the cook (stepped away). Timers keep their device
    /// deadlines — a pause never rewrites them.
    case pauseSession
    /// Back to cooking from a parked session.
    case resumeSession
    /// Cancel the cook explicitly. Nothing is saved; the snapshot
    /// clears (the host records nothing for a cancelled session).
    case cancelSession
    /// Done on the complete surface — the host dismisses the mode; the
    /// session is finished and its snapshot cleared.
    case closeComplete

    // Steps — the coach's touch equivalents (reducer-owned)

    /// Next step. From the last step this completes the cook into the
    /// remember surface.
    case nextStep(at: TimeInterval)
    /// Back a step. Never before the first.
    case backStep
    /// Repeat the step — re-present, no index change.
    case repeatStep
    /// "Show step N" / tapping a progress segment: jump to any step to
    /// read it.
    case jumpToStep(index: Int)

    // Timers — phone-controlled, local (reducer-owned)

    /// The add-tile's picker is host UI: the host presents a duration
    /// picker and dispatches `.setTimer` with the picked values. The
    /// reducer ignores this one — it is a routing signal only.
    case openTimerPicker

    /// Create a timer (the add-tile's picker, or the voice "timer N
    /// minutes"). The state machine creates it — the acknowledgement.
    case setTimer(label: String, seconds: Int, onDoneLine: String?)
    /// Tap a tile: pause / resume that timer.
    case toggleTimerPause(id: String)
    /// Long-press a tile: remove it.
    case removeTimer(id: String)
    /// The host's clock: fires due timers, exactly once each, and adds
    /// their check lines.
    case tick(now: TimeInterval)

    // Proposals — reads applied, mutations approved (reducer-owned)

    /// The host delivers assistant or local-table output. Redelivery
    /// of a known id is a no-op (idempotent). Reads appear at once;
    /// mutations wait for approval.
    case deliver([LeChefViewState.Proposal])
    /// The explicit approval action. Mutations only; the model cannot
    /// manufacture approval.
    case approveProposal(id: String)
    /// Decline a proposal (mutation or read) — it leaves the queue.
    case declineProposal(id: String)
    /// An approved mutation failed to execute host-side: the proposal
    /// returns to pending, a quiet line explains.
    case mutationFailed(id: String)
    /// The timer suggestion's chip ("Set 2 min timer"): creates the
    /// timer through the LOCAL timer path and consumes the suggestion.
    case applyTimerSuggestion(id: String)

    // Adapt (reducer-owned ingestion; the rescale arithmetic is the host's)

    /// The host applied locally-rescaled steps (amounts rescale
    /// predictably; time changes only under a reviewed rule the host
    /// checked). The announcement rides `deliver` as a read.
    case adaptedSteps([LeChefViewState.CookStep])

    // Camera look — push-to-look (lifecycle reducer-owned; the pipeline is the host's)

    /// "Look" — the viewfinder opens (host preview).
    case requestLook
    /// The viewfinder's shutter: the HOST performs the capture (one
    /// frame, or a clip of at most 3 seconds) and then dispatches
    /// `.lookCaptured` with what it actually captured. The reducer
    /// ignores this one — it is a routing signal only.
    case captureLook(LeChefViewState.LookCapture)
    /// The host reports the capture: one frame or a clip of at most 3
    /// seconds. An invalid capture is refused with an escape line,
    /// never trimmed.
    case lookCaptured(LeChefViewState.LookCapture)
    /// "Send" — the explicit upload.
    case sendLook
    /// The look's result arrived: observations, never a verdict. It
    /// enters the queue as a READ.
    case lookResultArrived(LeChefViewState.LookResult, proposalId: String)
    /// The upload failed; the look can be retried or dropped.
    case lookFailed
    /// Retry a failed look (the capture is the host's to hold).
    case retryLook
    /// Close the look (viewfinder or captured) — nothing was sent.
    case cancelLook

    // Voice / transcript (toggle reducer-owned; the link is the host's)

    /// "Turn on" / "Turn off" — the per-cook voice and chat opt-in.
    /// OFF is the default until a cost budget exists.
    case toggleTranscript
    /// Send a chat message (the fallback, behind the toggle). The
    /// user's turn lands in the live transcript; the host routes the
    /// send and delivers the answer.
    case sendChat(text: String)
    /// The host appends a live transcript turn (an answer, or a voice
    /// transcription).
    case transcriptAppended(speaker: LeChefViewState.Speaker, text: String)
    /// A parsed five-word command. Works only while the transcript is
    /// on; maps onto the same local operations as touch.
    case voiceCommand(LeChefViewState.VoiceCommand)

    // Remember (reducer-owned; the local write is the host's)

    /// Set the rating, 1...5. Anything else is refused.
    case setRating(Int)
    /// Edit the note draft (typed).
    case editNoteDraft(String)
    /// "Say it instead" is host UI: the host runs the draft flow and
    /// dispatches `.draftVoiceNote` with the transcription. The
    /// reducer ignores this one — it is a routing signal only.
    case requestVoiceNote
    /// "Say it instead" produced a transcription: a DRAFT for the user
    /// to confirm — never a saved note.
    case draftVoiceNote(String)
    /// The explicit save: rating and note saved locally, with a
    /// visible receipt. Idempotent while a save is in flight.
    case saveRecord
    /// The host confirmed the local write.
    case recordSaved
    /// The write failed: everything kept, the quiet error shows.
    case recordSaveFailed
}

/// The reducer: pure, total over intents. `LeChefViewState.apply(_:)` is
/// the convenience views use.
public enum LeChefReducer {

    /// The five-word vocabulary's timer label when the speaker gave no
    /// specific one.
    private static let voiceTimerLabel = "Timer"

    public static func reduced(_ state: LeChefViewState, by intent: LeChefIntent) -> LeChefViewState {
        var next = state
        switch intent {

        // MARK: Entry / stage machine

        case .enter(let recipe, let now):
            guard next.stage == .idle else { break }
            next = LeChefViewState(
                link: next.link, recipe: recipe, startedAt: now, steps: recipe.steps
            )
            next.stage = .cooking

        case .leaveSession:
            // The X: park (persisted for resume); the host dismisses.
            guard next.stage == .cooking else { break }
            next.stage = .paused

        case .pauseSession:
            guard next.stage == .cooking else { break }
            next.stage = .paused

        case .resumeSession:
            guard next.stage == .paused else { break }
            next.stage = .cooking

        case .cancelSession:
            // Explicit cancel: the session is abandoned. The recording
            // of a cancelled session is nil — nothing to resume,
            // nothing saved.
            guard next.stage == .cooking || next.stage == .paused else { break }
            next.stage = .cancelled

        case .closeComplete:
            guard next.stage == .complete else { break }
            next = LeChefViewState(link: next.link)

        // MARK: Steps

        case .nextStep(let now):
            guard next.stage == .cooking else { break }
            next.lastKnownNow = now // any timestamped intent is a clock reading
            if next.stepIndex + 1 >= next.steps.count {
                // The last step's Next ("Done cooking") completes the
                // cook into the remember surface. Not by a timer, not
                // by voice-anything else — an explicit step action.
                next.stage = .complete
                next.endedAt = now
            } else {
                next.stepIndex += 1
                next.checkLines = []
            }

        case .backStep:
            guard next.stage == .cooking else { break }
            guard next.stepIndex > 0 else { break }
            next.stepIndex -= 1
            next.checkLines = []

        case .repeatStep:
            // Re-present: no index change, nothing cleared but the
            // failure line (a repeat is a fresh look at the step).
            guard next.stage == .cooking else { break }
            next.mutationFailureLine = nil

        case .jumpToStep(let index):
            guard next.stage == .cooking else { break }
            guard next.steps.indices.contains(index), index != next.stepIndex else { break }
            next.stepIndex = index
            next.checkLines = []

        // MARK: Timers — phone-controlled, local

        case .openTimerPicker:
            // Routing only: the host presents the picker and dispatches
            // `.setTimer` with the picked values.
            break

        case .setTimer(let label, let seconds, let onDoneLine):
            // Allowed while cooking or paused: timers are independent
            // of the step position and of the link. Zero or negative
            // lengths are refused — a fake timer is never created.
            guard next.stage == .cooking || next.stage == .paused else { break }
            guard seconds > 0 else { break }
            next.timerCount += 1
            let timer = LeChefViewState.CookTimer(
                id: "timer-\(next.timerCount)",
                label: label,
                totalSeconds: seconds,
                endAt: next.lastKnownNow + Double(seconds),
                onDoneLine: onDoneLine
            )
            next.timers.append(timer)

        case .toggleTimerPause(let id):
            guard let index = next.timers.firstIndex(where: { $0.id == id }) else { break }
            guard !next.timers[index].fired else { break }
            if next.timers[index].endAt != nil {
                // Running → paused: freeze the remainder at the last
                // known clock.
                next.timers[index].pausedRemaining =
                    next.timers[index].remainingSeconds(at: next.lastKnownNow)
                next.timers[index].endAt = nil
            } else if let paused = next.timers[index].pausedRemaining {
                // Paused → running: a fresh deadline from the remainder.
                next.timers[index].endAt = next.lastKnownNow + Double(paused)
                next.timers[index].pausedRemaining = nil
            }

        case .removeTimer(let id):
            guard let index = next.timers.firstIndex(where: { $0.id == id }) else { break }
            let timer = next.timers.remove(at: index)
            // A fired timer's check line goes with it.
            if let line = timer.onDoneLine {
                next.checkLines.removeAll { $0 == line }
            }

        case .tick(let now):
            next.lastKnownNow = now
            for index in next.timers.indices {
                let timer = next.timers[index]
                guard timer.isRunning, let endAt = timer.endAt, now >= endAt else { continue }
                next.timers[index].fired = true
                next.timers[index].endAt = nil
                if let line = timer.onDoneLine, !line.isEmpty {
                    next.checkLines.append(line)
                }
            }

        // MARK: Proposals

        case .deliver(let incoming):
            var known = Set(next.proposals.map { $0.id })
            for proposal in incoming where !known.contains(proposal.id) {
                known.insert(proposal.id)
                next.proposals.append(proposal)
            }
            next.mutationFailureLine = nil

        case .approveProposal(let id):
            // The ONE path that applies a mutation. Reads are already
            // applied without ceremony — approving one is a no-op.
            guard let index = next.proposals.firstIndex(where: { $0.id == id }) else { break }
            guard !next.proposals[index].isRead else { break }
            next.proposals[index].isApplied = true
            next.mutationFailureLine = nil

        case .declineProposal(let id):
            next.proposals.removeAll { $0.id == id }
            next.mutationFailureLine = nil

        case .mutationFailed(let id):
            guard let index = next.proposals.firstIndex(where: { $0.id == id }) else { break }
            next.proposals[index].isApplied = false
            next.mutationFailureLine = "That change didn't go through. Nothing was altered."

        case .applyTimerSuggestion(let id):
            // The suggestion's chip: the LOCAL timer path, same as the
            // add-tile. Not an approval — the suggestion is a read.
            guard let index = next.proposals.firstIndex(where: { $0.id == id }) else { break }
            guard case .timerSuggestion(let seconds, let label) = next.proposals[index].payload,
                  seconds > 0
            else { break }
            next.timerCount += 1
            next.timers.append(
                LeChefViewState.CookTimer(
                    id: "timer-\(next.timerCount)",
                    label: label ?? Self.voiceTimerLabel,
                    totalSeconds: seconds,
                    endAt: next.lastKnownNow + Double(seconds)
                )
            )
            next.proposals.remove(at: index)

        // MARK: Adapt

        case .adaptedSteps(let steps):
            // The host's local rescale or an executed, approved change.
            // The index stays if the new list still holds it, else it
            // clamps to the last step — never out of range.
            guard !steps.isEmpty else { break }
            next.steps = steps
            if next.stepIndex >= steps.count {
                next.stepIndex = steps.count - 1
            }
            next.checkLines = []

        // MARK: Camera look — push-to-look

        case .requestLook:
            guard next.stage == .cooking || next.stage == .paused else { break }
            guard next.lookStage == .none else { break }
            next.lookStage = .viewfinder
            next.lookProblem = nil

        case .captureLook:
            // Routing only: the host performs the capture and then
            // dispatches `.lookCaptured` with what it actually captured.
            break

        case .lookCaptured(let capture):
            guard next.lookStage == .viewfinder else { break }
            guard capture.isValid else {
                // Refused, not trimmed: an over-long clip never sends.
                next.lookProblem = .clipTooLong
                break
            }
            next.lookStage = .captured
            next.lookProblem = nil

        case .sendLook:
            // The explicit upload — never automatic.
            guard next.lookStage == .captured else { break }
            next.lookStage = .uploading

        case .lookResultArrived(let result, let proposalId):
            guard next.lookStage == .uploading else { break }
            // The result is a READ: applied without ceremony, and it
            // can never carry a safety verdict — the payload has no
            // field for one.
            var known = Set(next.proposals.map { $0.id })
            if !known.contains(proposalId) {
                known.insert(proposalId)
                next.proposals.append(
                    LeChefViewState.Proposal(id: proposalId, job: .coach, payload: .lookResult(result))
                )
            }
            next.lookStage = .none
            next.lookProblem = nil

        case .lookFailed:
            guard next.lookStage == .uploading else { break }
            next.lookStage = .failed
            next.lookProblem = .sendFailed

        case .retryLook:
            guard next.lookStage == .failed else { break }
            // The capture is the host's to hold; re-enter the upload.
            next.lookStage = .uploading
            next.lookProblem = nil

        case .cancelLook:
            // Nothing sent, nothing remembered.
            next.lookStage = .none
            next.lookProblem = nil

        // MARK: Voice / transcript

        case .toggleTranscript:
            next.isTranscriptOn.toggle()
            // Turning the transcript off drops the live transcript with
            // it — off means just the steps, nothing held.
            if !next.isTranscriptOn {
                next.transcript = []
                next.transcriptCount = 0
            }

        case .sendChat(let text):
            // The fallback, behind the toggle. With the toggle off
            // there is no chat — the text goes nowhere.
            guard next.isTranscriptOn else { break }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }
            next.transcriptCount += 1
            next.transcript.append(
                LeChefViewState.TranscriptTurn(
                    id: "turn-\(next.transcriptCount)", speaker: .you, text: trimmed
                )
            )

        case .transcriptAppended(let speaker, let text):
            // Live-session data only; the persisted state has no field
            // to record a turn in.
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }
            next.transcriptCount += 1
            next.transcript.append(
                LeChefViewState.TranscriptTurn(
                    id: "turn-\(next.transcriptCount)", speaker: speaker, text: trimmed
                )
            )

        case .voiceCommand(let command):
            // The five words, only while the transcript is on (voice
            // off means just the steps — nothing listens). Every
            // command maps onto the touch intent; none reaches the
            // approval path or the record save.
            guard next.isTranscriptOn else { break }
            switch command {
            case .next:
                return reduced(next, by: .nextStep(at: next.lastKnownNow))
            case .back:
                return reduced(next, by: .backStep)
            case .repeatStep:
                return reduced(next, by: .repeatStep)
            case .timer(let seconds):
                return reduced(next, by: .setTimer(label: Self.voiceTimerLabel, seconds: seconds, onDoneLine: nil))
            case .show(let step):
                if let step {
                    return reduced(next, by: .jumpToStep(index: step - 1))
                }
                return reduced(next, by: .repeatStep)
            }

        // MARK: Remember

        case .setRating(let stars):
            guard next.stage == .complete else { break }
            guard (1...5).contains(stars) else { break }
            next.rating = stars

        case .editNoteDraft(let text):
            guard next.stage == .complete else { break }
            next.noteDraft = text
            next.showsSaveReceipt = false

        case .requestVoiceNote:
            // Routing only: the host runs the draft flow and dispatches
            // `.draftVoiceNote` with the transcription.
            break

        case .draftVoiceNote(let text):
            // "Say it instead": a transcription arrives as a DRAFT.
            // Confirming it is the explicit save; a transcript alone
            // never saves.
            guard next.stage == .complete else { break }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { break }
            next.noteDraft = trimmed
            next.showsSaveReceipt = false

        case .saveRecord:
            // The explicit save. Idempotent while in flight; refused
            // when there is nothing to save.
            guard next.stage == .complete else { break }
            guard !next.isSavingRecord else { break }
            guard next.rating != nil
                    || !(next.noteDraft ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            else { break }
            next.savedNote = next.noteDraft?.trimmingCharacters(in: .whitespaces)
            next.isSavingRecord = true
            next.saveFailed = false

        case .recordSaved:
            guard next.isSavingRecord else { break }
            next.isSavingRecord = false
            next.showsSaveReceipt = true

        case .recordSaveFailed:
            guard next.isSavingRecord else { break }
            next.isSavingRecord = false
            next.saveFailed = true
        }
        return next
    }
}

extension LeChefViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: LeChefIntent) {
        self = LeChefReducer.reduced(self, by: intent)
    }
}
