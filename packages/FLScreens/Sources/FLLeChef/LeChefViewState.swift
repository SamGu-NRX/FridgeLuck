// FLLeChef — the cook-mode session's view state.
//
// LeChef is not a tab (SPEC §2): it is a mode entered from a recipe or
// Tonight, presented by the host as a destination. This state models the
// whole session — the mid-cook surface and the cook-complete surface are
// stages of one machine, one proposal queue, one remember surface.
//
// Binding rules this state encodes (SPEC §4, §3.1, §3.4):
//
// - Five jobs — plan, substitute, coach, adapt, remember — each with a
//   reliable LOCAL core. The assistant link (`.live` / `.offline`) gates
//   nothing local: steps, timers, the reviewed swap table's proposals,
//   and the record save all progress and complete a cook at zero
//   connectivity.
// - Typed proposals distinguish READS (applied without ceremony — shown
//   as soon as delivered) from MUTATIONS (require an explicit approval
//   action; the model cannot manufacture approval — only
//   `.approveProposal` applies one, and voice commands can never reach
//   it). Phone-controlled timers are NOT proposals: set, pause and
//   complete live in the state machine; a timer suggestion is a read
//   whose "Set N min timer" chip routes to the same local timer intent
//   as the touch control.
// - Camera: push-to-look is the built candidate — viewfinder, explicit
//   upload, a look sends a single frame or a clip of at most 3 seconds
//   (`LookCapture` enforces the cap). Continuous camera + voice is the
//   round's other candidate, flagged but deliberately NOT built
//   (`LeChefCameraCandidate`). A look NEVER yields a safety verdict:
//   `LookResult` carries observations and nothing else — doneness and
//   safety have no field to arrive in, and the display always pairs the
//   result with what the look cannot assess.
// - Voice is opt-in per cook and "Just the steps" is the DEFAULT until a
//   cost budget exists; the transcript/chat fallback sits behind the
//   same toggle, off by default.
// - Nothing persists beyond the live session unless the user explicitly
//   saves: `LeChefPersistedState` is the only on-device resume shape and
//   is built by an explicit field-by-field recording — it has no frame,
//   transcript or look field BY CONSTRUCTION, and the saved cook record
//   carries only the rating and the explicitly saved one-line note.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLLeChefTests.

import Foundation

/// The whole cook session as a value.
public struct LeChefViewState: Equatable, Sendable {

    // MARK: Stage

    /// Where the session stands. `complete` is the remember surface
    /// (rating, note, receipt); `cancelled` and the post-`closeComplete`
    /// reset are the ends the host routes away from.
    public enum Stage: Equatable, Sendable {
        case idle
        case cooking
        case paused
        case complete
        case cancelled
    }

    /// The assistant link. Its ONLY effect is copy and the voice
    /// grammar's fallback — every local core works at `.offline`.
    public enum Link: Equatable, Sendable {
        case live
        case offline
    }

    // MARK: The five jobs (SPEC §4)

    /// Plan, substitute, coach, adapt, remember — each with a local core
    /// that works with no network. The lines are the session's own
    /// statement of where each job runs.
    public enum Job: String, Sendable, CaseIterable {
        case plan
        case substitute
        case coach
        case adapt
        case remember

        /// The job's local core, in the session's voice. Every line is
        /// true at `.offline` — that is the contract.
        public var localCoreLine: String {
            switch self {
            case .plan: return "Planning from your pantry runs on this phone."
            case .substitute: return "The reviewed swap table runs on this phone."
            case .coach: return "Steps and timers run on this phone."
            case .adapt: return "Rescaling runs on this phone."
            case .remember: return "Ratings and notes save on this phone."
            }
        }
    }

    // MARK: Recipe payload (host-supplied at entry)

    /// One segment of a step's body. Quantity runs ride separately so
    /// the views can emphasize them; the plain text is always available.
    public enum StepSegment: Equatable, Sendable {
        case text(String)
        case quantity(String)
    }

    /// One recipe step, as the host's cook flow supplies it. A step
    /// without a natural timer carries none — one is never invented.
    public struct CookStep: Equatable, Sendable, Identifiable {

        public var id: String
        /// The step's short name ("Noodles in") — the caption beside the
        /// step number and the Next button's preview.
        public var name: String
        /// The body, as segments in order.
        public var segments: [StepSegment]
        /// This step's natural timer, when the recipe has one: the
        /// label ("Noodles"), the length, and the check line the step
        /// gains when it fires ("Rice done — stir the sauce in").
        public var timerLabel: String?
        public var timerSeconds: Int?
        public var onDoneLine: String?

        public init(
            id: String, name: String, segments: [StepSegment],
            timerLabel: String? = nil, timerSeconds: Int? = nil, onDoneLine: String? = nil
        ) {
            self.id = id
            self.name = name
            self.segments = segments
            self.timerLabel = timerLabel
            self.timerSeconds = timerSeconds
            self.onDoneLine = onDoneLine
        }

        /// The body as plain text (accessibility, tests).
        public var plainBody: String {
            segments.map { segment -> String in
                switch segment {
                case .text(let text): return text
                case .quantity(let quantity): return quantity
                }
            }.joined()
        }
    }

    /// The recipe the session cooks, as the host hands it over at
    /// entry — from a recipe document or Tonight's pick.
    public struct CookRecipe: Equatable, Sendable {

        public var revisionId: String
        public var dishName: String
        public var servings: Int
        public var steps: [CookStep]

        public init(revisionId: String, dishName: String, servings: Int, steps: [CookStep]) {
            self.revisionId = revisionId
            self.dishName = dishName
            self.servings = servings
            self.steps = steps
        }
    }

    // MARK: Timers — phone-controlled, state-machine owned

    /// One cook timer. Deadlines are epoch seconds the host's clock
    /// supplies; the state computes remaining time from `now`, so a
    /// persisted deadline survives a kill/reopen still counting. A
    /// timer is acknowledged only after the state machine created it —
    /// there is no other creation path.
    public struct CookTimer: Equatable, Sendable, Identifiable {

        public var id: String
        public var label: String
        public var totalSeconds: Int
        /// The epoch deadline while running; nil while paused.
        public var endAt: TimeInterval?
        /// Remaining seconds while paused; nil while running.
        public var pausedRemaining: Int?
        /// A fired timer reads 0:00 and stays until removed; it never
        /// advances the step by itself.
        public var fired: Bool
        /// The check line the step gains when this timer fires.
        public var onDoneLine: String?

        public init(
            id: String, label: String, totalSeconds: Int,
            endAt: TimeInterval? = nil, pausedRemaining: Int? = nil,
            fired: Bool = false, onDoneLine: String? = nil
        ) {
            self.id = id
            self.label = label
            self.totalSeconds = totalSeconds
            self.endAt = endAt
            self.pausedRemaining = pausedRemaining
            self.fired = fired
            self.onDoneLine = onDoneLine
        }

        public var isRunning: Bool { !fired && endAt != nil }
        public var isPaused: Bool { !fired && pausedRemaining != nil }

        /// Remaining seconds at `now`: 0 once fired; the paused
        /// remainder while paused; the deadline arithmetic while running.
        public func remainingSeconds(at now: TimeInterval) -> Int {
            if fired { return 0 }
            if let pausedRemaining { return max(0, pausedRemaining) }
            guard let endAt else { return 0 }
            return max(0, Int(endAt - now))
        }
    }

    // MARK: Proposals — reads vs. approved mutations

    /// What a proposal carries. The read cases are applied without
    /// ceremony (shown as soon as delivered). The mutation cases wait
    /// for an explicit approval action — no delivery path, voice or
    /// otherwise, can apply them. There is deliberately NO timer case
    /// that executes: timers are phone-controlled and live in the state
    /// machine; a suggestion is a read whose chip routes to the local
    /// timer intent.
    public enum Payload: Equatable, Sendable {

        // Reads — applied without ceremony.

        /// A coach answer or note, shown in the LeChef panel.
        case information(text: String)
        /// The mock's "Want a 2 min timer to check again?" — a read;
        /// its "Set N min timer" chip calls the LOCAL timer intent.
        case timerSuggestion(seconds: Int, label: String?)
        /// A camera look's result: what a picture can show. Never a
        /// safety verdict — see `LookResult`.
        case lookResult(LookResult)
        /// The local rescale's announcement ("one thigh, so 6 min not
        /// 8"), delivered when the host applies adapted steps.
        case adaptAnnouncement(text: String)

        // Mutations — explicit approval required.

        /// A swap from the reviewed table. `difference` describes the
        /// difference ("a little sharper") and never promises "no
        /// change"; `allergenRecheck` is the host's recheck line for
        /// all eaters.
        case substitution(name: String, difference: String, allergenRecheck: String)
        /// An assistant-proposed change to amounts or times, with the
        /// reviewed rule that supports it. Approval is a receipt the
        /// host executes; the state never recomputes a recipe.
        case adaptChange(text: String, rule: String)
    }

    /// One typed proposal in the queue.
    public struct Proposal: Equatable, Sendable, Identifiable {

        public var id: String
        public var job: Job
        public var payload: Payload
        /// Mutations only: set by the explicit approval action and by
        /// nothing else.
        public var isApplied: Bool

        public init(id: String, job: Job, payload: Payload, isApplied: Bool = false) {
            self.id = id
            self.job = job
            self.payload = payload
            self.isApplied = isApplied
        }

        /// Reads are applied without ceremony; mutations wait.
        public var isRead: Bool {
            switch payload {
            case .information, .timerSuggestion, .lookResult, .adaptAnnouncement:
                return true
            case .substitution, .adaptChange:
                return false
            }
        }
    }

    // MARK: Camera look — push-to-look (the built candidate)

    /// The round's two camera candidates (SPEC §4). `pushToLook` is
    /// built: a visible viewfinder and an explicit upload of one frame
    /// or a clip of at most 3 seconds. `continuousVoice` is Sam's
    /// stage-4 candidate — flagged here so the round scores it, and
    /// deliberately NOT built: no continuous capture path exists in
    /// this module.
    public enum CameraCandidate: String, Sendable, CaseIterable {
        case pushToLook
        case continuousVoice

        /// Only push-to-look is built.
        public var isBuilt: Bool { self == .pushToLook }

        /// The built set — the candidate the session's UI offers.
        public static var built: [CameraCandidate] { [.pushToLook] }
    }

    /// What a look sends: a single frame, or a clip of at most
    /// `maxClipSeconds`. An over-long clip is invalid — the state
    /// refuses it rather than trimming it silently.
    public enum LookCapture: Equatable, Sendable {

        case singleFrame
        case clip(seconds: Int)

        /// The clip cap, in seconds (SPEC §4: "a clip of up to 3 seconds").
        public static let maxClipSeconds = 3

        public var isValid: Bool {
            switch self {
            case .singleFrame: return true
            case .clip(let seconds): return seconds >= 1 && seconds <= Self.maxClipSeconds
            }
        }
    }

    /// Where the look lifecycle stands: request → captured → uploading
    /// → result. The result leaves the lifecycle as a READ proposal;
    /// the lifecycle never holds image bytes — the host owns the frame,
    /// this state carries only stages and captions.
    public enum LookStage: Equatable, Sendable {
        case none
        case viewfinder
        case captured
        case uploading
        case failed
    }

    /// Why a look did not complete. Escapes, never dead ends.
    public enum LookProblem: Equatable, Sendable {
        /// The host reported an over-long clip — it was refused, not trimmed.
        case clipTooLong
        /// The upload failed; the look can be retried or dropped.
        case sendFailed
    }

    /// What a picture can show: observations, verbatim from the host.
    /// There is deliberately NO doneness, safety, verdict or temperature
    /// field — a look's claims have nowhere to arrive from (SPEC §3.1:
    /// a camera look never gives a safety verdict). The display always
    /// pairs the result with `cannotAssessDisplay`.
    public struct LookResult: Equatable, Sendable {

        /// What the picture shows (browning, size, consistency).
        public var observedLines: [String]

        public init(observedLines: [String]) {
            self.observedLines = observedLines
        }
    }

    // MARK: Transcript (live session only — never persisted)

    public enum Speaker: Equatable, Sendable {
        case you
        case lechef
    }

    /// One live transcript turn. Lives only in the live session state;
    /// `LeChefPersistedState` has no field to record one in.
    public struct TranscriptTurn: Equatable, Sendable, Identifiable {

        public var id: String
        public var speaker: Speaker
        public var text: String

        public init(id: String, speaker: Speaker, text: String) {
            self.id = id
            self.speaker = speaker
            self.text = text
        }
    }

    // MARK: The five-word vocabulary, voice side

    /// The coach's five words (SPEC §4: next, back, repeat, timer N
    /// minutes, show), parsed by the HOST (on-device offline, Live when
    /// connected) and delivered as intents. A voice command maps onto
    /// the same local operations as its touch equivalent and can never
    /// approve a mutation, save the record, or create anything the
    /// touch path cannot.
    public enum VoiceCommand: Equatable, Sendable {
        case next
        case back
        case repeatStep
        /// "Timer N minutes" — routed to the local timer intent.
        case timer(seconds: Int)
        /// "Show" re-presents the current step; "show step N" jumps.
        case show(step: Int?)
    }

    // MARK: State

    public var stage: Stage
    public var link: Link

    /// The session's recipe, as entered. Never mutated by this layer —
    /// adaptations arrive as whole replacement steps from the host.
    public var recipe: CookRecipe?
    /// Epoch the cook started, the host's clock.
    public var startedAt: TimeInterval
    /// Epoch the steps finished (set on entering `complete`).
    public var endedAt: TimeInterval?

    public var steps: [CookStep]
    public var stepIndex: Int

    public var timers: [CookTimer]
    /// Check lines gained from fired timers ("Rice done — stir the
    /// sauce in"). Cleared when the step changes.
    public var checkLines: [String]

    public var proposals: [Proposal]
    /// Set when an approved mutation failed to execute host-side; the
    /// proposal returns to pending. Quiet line, never an alert.
    public var mutationFailureLine: String?

    public var lookStage: LookStage
    public var lookProblem: LookProblem?

    /// Voice/transcript opt-in, PER COOK. "Just the steps" is the
    /// default until a cost budget exists — every new session starts
    /// here, off.
    public var isTranscriptOn: Bool
    /// The live transcript. Only meaningful while `isTranscriptOn`;
    /// never persisted.
    public var transcript: [TranscriptTurn]
    var transcriptCount: Int

    // Remember (the complete surface)

    public var rating: Int?
    /// The note as being typed or voice-drafted — NOT saved until the
    /// explicit save action. A voice transcript alone never saves.
    public var noteDraft: String?
    /// The explicitly saved one-line note. The only note field that
    /// persists.
    public var savedNote: String?
    public var isSavingRecord: Bool
    public var showsSaveReceipt: Bool
    public var saveFailed: Bool

    /// The nutrition line, host-verbatim ("About 520 kcal per serving ·
    /// logged 9 of your 14 meals this week"). Never derived here.
    public var nutritionLine: String?

    /// The host's last clock reading — the deadline base for timers
    /// created by voice and the "minutes in" denominator between ticks.
    public var lastKnownNow: TimeInterval

    var timerCount: Int

    public init(
        stage: Stage = .idle, link: Link = .live, recipe: CookRecipe? = nil,
        startedAt: TimeInterval = 0, endedAt: TimeInterval? = nil,
        steps: [CookStep] = [], stepIndex: Int = 0,
        timers: [CookTimer] = [], checkLines: [String] = [],
        proposals: [Proposal] = [], mutationFailureLine: String? = nil,
        lookStage: LookStage = .none, lookProblem: LookProblem? = nil,
        isTranscriptOn: Bool = false, transcript: [TranscriptTurn] = [],
        rating: Int? = nil, noteDraft: String? = nil, savedNote: String? = nil,
        isSavingRecord: Bool = false, showsSaveReceipt: Bool = false,
        saveFailed: Bool = false, nutritionLine: String? = nil,
        lastKnownNow: TimeInterval = 0
    ) {
        self.stage = stage
        self.link = link
        self.recipe = recipe
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.steps = steps
        self.stepIndex = stepIndex
        self.timers = timers
        self.checkLines = checkLines
        self.proposals = proposals
        self.mutationFailureLine = mutationFailureLine
        self.lookStage = lookStage
        self.lookProblem = lookProblem
        self.isTranscriptOn = isTranscriptOn
        self.transcript = transcript
        self.transcriptCount = transcript.count
        self.rating = rating
        self.noteDraft = noteDraft
        self.savedNote = savedNote
        self.isSavingRecord = isSavingRecord
        self.showsSaveReceipt = showsSaveReceipt
        self.saveFailed = saveFailed
        self.nutritionLine = nutritionLine
        self.lastKnownNow = lastKnownNow
        self.timerCount = timers.count
    }

    // MARK: Restore — the persisted "kill the app at step 4" path

    /// Rebuild a session from the host's persisted snapshot (the mock's
    /// persisted state: "Kill the app at step 4; reopen to step 4 with
    /// the timer still counting"). The host re-supplies the recipe's
    /// steps and the current time; everything else comes from the
    /// snapshot.
    public init(restoring persisted: LeChefPersistedState, steps: [CookStep], at now: TimeInterval) {
        self.init(
            stage: persisted.stage,
            link: .live,
            recipe: CookRecipe(
                revisionId: persisted.revisionId, dishName: persisted.dishName,
                servings: persisted.servings, steps: steps
            ),
            startedAt: persisted.startedAt,
            steps: steps,
            stepIndex: min(max(0, persisted.stepIndex), max(0, steps.count - 1)),
            timers: persisted.timers.map {
                CookTimer(
                    id: $0.id, label: $0.label, totalSeconds: $0.totalSeconds,
                    endAt: $0.endAt, pausedRemaining: $0.pausedRemaining,
                    fired: $0.fired, onDoneLine: $0.onDoneLine
                )
            },
            isTranscriptOn: false,
            rating: persisted.rating,
            savedNote: persisted.savedNote,
            lastKnownNow: now
        )
        self.timerCount = persisted.timers.count
    }

    // MARK: Current step

    public var currentStep: CookStep? {
        guard steps.indices.contains(stepIndex) else { return nil }
        return steps[stepIndex]
    }

    /// The next step's name — the Next button's preview ("Sauce goes in
    /// after this" shows the step's name). Nil on the last step.
    public var nextStepPreview: String? {
        guard steps.indices.contains(stepIndex + 1) else { return nil }
        return steps[stepIndex + 1].name
    }

    // MARK: Display grammar — the mid-cook surface

    /// "Step 4 of 8 · 11 min in" — the header's mono progress line.
    public func headerProgressDisplay(at now: TimeInterval) -> String? {
        guard stage == .cooking || stage == .paused || stage == .complete else { return nil }
        let minutes = max(0, Int((now - startedAt) / 60))
        return "Step \(stepIndex + 1) of \(steps.count) · \(minutes) min in"
    }

    /// The primary button's title: "Next", or "Done cooking" on the
    /// final step.
    public var nextButtonTitle: String {
        stepIndex + 1 >= steps.count ? "Done cooking" : "Next"
    }

    /// "Voice off — Just the steps" — the default entrance's line, with
    /// a quiet "Turn on" beside it.
    public var voiceOffDisplay: String { "Voice off — Just the steps" }

    /// The voice row's hint, in the session's three voice states:
    /// listening (connected), on-device listening (offline — the five
    /// words still work), and off (the default).
    public var voiceHintDisplay: String? {
        guard isTranscriptOn else { return nil }
        switch link {
        case .live:
            return "Listening. Say next, back, repeat, show, or timer 3 minutes."
        case .offline:
            return "On-device listening. Say: next · back · repeat · timer N minutes · show"
        }
    }

    /// One line under the header when the link is down. Local cores
    /// keep working — the line says exactly that.
    public var offlineNoticeDisplay: String? {
        link == .offline ? "LeChef is offline. Steps and timers still work." : nil
    }

    /// The look row's caption — the push-to-look contract in one line.
    public var lookCaptionDisplay: String {
        "Camera look: one frame, viewfinder visible, never a safety verdict."
    }

    /// What a look cannot assess — always rendered with a look result.
    public var lookCannotAssessDisplay: String {
        "A look can't check doneness or safety — the thermometer decides."
    }

    /// The look problem's copy (an escape, never a dead end).
    public var lookProblemDisplay: String? {
        switch lookProblem {
        case .clipTooLong: return "Clips run at most 3 seconds — send one frame or hold shorter."
        case .sendFailed: return "Couldn't send that look. Try again or keep cooking."
        case nil: return nil
        }
    }

    /// A proposal's rendered lines for the LeChef panel: the payload's
    /// own words, host-verbatim where the host supplied them.
    public func proposalDisplay(_ proposal: Proposal) -> [String] {
        switch proposal.payload {
        case .information(let text):
            return [text]
        case .timerSuggestion(let seconds, _):
            return ["Want a \(Self.minutesText(seconds)) timer to check again?"]
        case .lookResult(let result):
            return result.observedLines + [lookCannotAssessDisplay]
        case .adaptAnnouncement(let text):
            return [text]
        case .substitution(let name, let difference, let recheck):
            return [name, difference, recheck]
        case .adaptChange(let text, let rule):
            return [text, rule]
        }
    }

    /// The timer suggestion's chip title ("Set 2 min timer") — the
    /// mock's clear action copy.
    public func timerSuggestionTitle(seconds: Int) -> String {
        "Set \(Self.minutesText(seconds)) timer"
    }

    /// "2 min" for whole minutes, otherwise seconds ("90 sec").
    public static func minutesText(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0
            ? "\(seconds / 60) min"
            : "\(seconds) sec"
    }

    // MARK: Display grammar — the complete surface

    /// "Cooked in 24 min · 2 servings" — derived from the session's own
    /// clocks, never guessed.
    public var cookedDurationLine: String? {
        guard let endedAt else { return nil }
        let minutes = max(0, Int((endedAt - startedAt) / 60))
        return "Cooked in \(minutes) min · \(recipe?.servings ?? 0) servings"
    }

    /// The save receipt — the visible receipt the remember job owes.
    public var saveReceiptDisplay: String { "Saved on this phone." }

    /// The complete surface's privacy line.
    public var privacyLine: String { "Nothing is shared until you choose to." }

    /// The record's subtitle: saving is local; sharing is separate.
    public var completeSubtitle: String { "Saved on this phone. Sharing is a separate choice." }

    // MARK: The five-job surface

    /// Which jobs the session surface exposes at this stage. Plan rides
    /// the entry (Tonight's allocation reserved this cook), coach,
    /// substitute and adapt are the mid-cook surface, remember is the
    /// complete surface.
    public var activeJobs: [Job] {
        switch stage {
        case .idle:
            return []
        case .cooking, .paused:
            return [.plan, .coach, .substitute, .adapt]
        case .complete:
            return [.remember]
        case .cancelled:
            return []
        }
    }
}
