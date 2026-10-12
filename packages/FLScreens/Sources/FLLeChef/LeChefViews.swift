// FLLeChef — the SwiftUI flow.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
//
// Craft rules this file encodes (the Direction H cook-lechef mock + the
// binding constraints; SPEC §4 corrected copy wins over the mock's):
// - The whole surface pins the COOK palette: it is a cook-mode object,
//   like the timer tile — it does not recolour per ambient scheme. Every
//   colour goes through `Theme.swiftColor(_, in: .hob)`, which resolves
//   through FLRenderPaletteMapping's tables whichever direction theme is
//   configured — this file never names a direction.
// - Type through `.flType`, radius through `Radius`, spacing through
//   `Density.deciding` (the token doc names cook-mode step and
//   cook-complete generous). No visual value of its own.
// - Timers are the shared `FLTimerTile` (tap pauses, long-press removes,
//   linear ring, hob digits). The state machine owns the lifecycle; the
//   view only renders it.
// - Push-to-look: the viewfinder is an overlay with the host's preview;
//   capture is explicit (a frame or a clip button), send is explicit, a
//   problem is an escape line — never a dead end, never a verdict.
// - Voice is off by default: the row leads with "Voice off — Just the
//   steps" and a quiet Turn on. Chat appears only behind the toggle.
// - Proposals never manufacture their own success. Approval routes to
//   the host's authority seam (the intent stream); the panel shows
//   "Waiting on the phone…" until a receipt returns, and "Done" renders
//   only a returned receipt (`.mutationReceipt`) — the phone's word.
// - No photos anywhere on this surface: nothing here applies a photo
//   rule — a cook-mode look preview is the host's live camera surface,
//   not a captured photo asset.
// - The mock's serif completion title and inline mono quantity runs have
//   no token-backed role; the surface uses `.screenTitle` and `.quantity`
//   instead. Recorded in docs/screens/part5-notes.md.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem

/// The LeChef destination — the cook mode the host presents (full
/// screen, sheet or navigation destination) from a recipe or from
/// Tonight's pick. NOT a tab: nothing here joins the Part 2 shell's
/// dock. The host drives the session by applying `LeChefIntent`s to the
/// state it owns and passing the binding in.
public struct LeChefView: View {

    @Binding var state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void
    /// Host-supplied viewfinder preview for a camera look (iOS only),
    /// the same seam as Scan's capture preview. Nil falls back to the
    /// placeholder surface; the shutter still routes through the host.
    let lookPreview: AnyView?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: Binding<LeChefViewState>,
        onIntent: @escaping (LeChefIntent) -> Void,
        lookPreview: AnyView? = nil
    ) {
        _state = state
        self.onIntent = onIntent
        self.lookPreview = lookPreview
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: .hob).ignoresSafeArea()
            switch state.stage {
            case .idle:
                LeChefIdleSurface(state: state, onIntent: onIntent)
            case .cooking:
                LeChefCookSurface(state: state, onIntent: onIntent)
            case .paused:
                LeChefPausedSurface(state: state, onIntent: onIntent)
            case .complete:
                LeChefCompleteSurface(state: state, onIntent: onIntent)
            case .cancelled:
                cancelledSurface
            }
            // lookOverlay is a non-optional view — it renders EmptyView
            // when no look is open — so the body uses it directly; an
            // `if let` on it would not compile.
            lookOverlay
        }
        // The cook surface pins the cook palette — a cook-mode object
        // does not recolour per ambient scheme. The environment follows
        // so system controls match the dark appearance.
        .flScheme(.hob)
        .animation(reduceMotion ? nil : .fl(.fade), value: state.stage)
        .animation(reduceMotion ? nil : .fl(.fade), value: state.lookStage)
        .accessibilityIdentifier("fl.lechef.screen")
    }

    /// The push-to-look overlay while a look is open.
    @ViewBuilder
    private var lookOverlay: some View {
        switch state.lookStage {
        case .viewfinder, .captured, .uploading, .failed:
            LeChefLookOverlay(
                state: state, onIntent: onIntent, lookPreview: lookPreview
            )
        case .none:
            EmptyView()
        }
    }

    private var cancelledSurface: some View {
        VStack(spacing: CGFloat(Density.deciding.blockGap)) {
            Text("Cook cancelled.")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
            Text("Nothing was saved. Start again from the recipe whenever you like.")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
        }
        .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
        .accessibilityIdentifier("fl.lechef.cancelled")
    }
}

// MARK: - Idle

/// Rarely seen — the host enters with a recipe. A quiet landing, not an
/// error state.
private struct LeChefIdleSurface: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
            Text("LeChef")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
                .accessibilityIdentifier("fl.lechef.idle.title")
                .accessibilityAddTraits(.isHeader)
            Text("Enter from a recipe or from Tonight to cook with me. Steps and timers run on this phone.")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
                .accessibilityIdentifier("fl.lechef.idle.caption")
            Spacer()
        }
        .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - The mid-cook surface

private struct LeChefCookSurface: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let offline = state.offlineNoticeDisplay {
                Text(offline)
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.yolk, in: .hob))
                    .accessibilityIdentifier("fl.lechef.offline")
                    .padding(.top, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
                    stepCard
                    checkLines
                    LeChefProposalPanel(state: state, onIntent: onIntent)
                    LeChefTimerStrip(state: state, onIntent: onIntent)
                    LeChefVoiceSection(state: state, onIntent: onIntent)
                }
                .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
                .padding(.top, CGFloat(Density.deciding.blockGap))
                .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            controlBar
        }
    }

    private var header: some View {
        let now = Date().timeIntervalSince1970
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(state.recipe?.dishName ?? "Cook")
                    .flType(.screenTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
                    .accessibilityIdentifier("fl.lechef.dishTitle")
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    onIntent(.leaveSession)
                } label: {
                    Image(systemName: "xmark")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
                        .padding(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FLButtonStyle())
                .accessibilityLabel("Leave cook")
                .accessibilityIdentifier("fl.lechef.leaveCook")
            }
            Text(state.headerProgressDisplay(at: now) ?? "")
                .flType(.sectionLabel)
                .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                .accessibilityIdentifier("fl.lechef.progressLine")
            LeChefProgressSegments(state: state, onIntent: onIntent)
        }
        .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
        .padding(.top, 16)
    }

    private var stepCard: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap / 2)) {
            if let step = state.currentStep {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(state.stepIndex + 1)")
                        .flType(.fitCount)
                        .foregroundStyle(Theme.swiftColor(.yolk, in: .hob))
                    Text(step.name)
                        .flType(.screenTitle)
                        .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fl.lechef.stepCard")
                Text(step.plainBody)
                    .flType(.cookStep)
                    .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
                    .accessibilityIdentifier("fl.lechef.stepBody")
            }
        }
    }

    @ViewBuilder
    private var checkLines: some View {
        ForEach(Array(state.checkLines.enumerated()), id: \.offset) { _, line in
            Text(line)
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.yolk, in: .hob))
                .accessibilityIdentifier("fl.lechef.checkLine")
        }
    }

    private var controlBar: some View {
        HStack(spacing: CGFloat(Density.deciding.blockGap / 2)) {
            FLButton(.secondary, "Back") {
                onIntent(.backStep)
            }
            .disabled(state.stepIndex == 0)
            .accessibilityIdentifier("fl.lechef.back")
            FLButton(.secondary, "+ Timer") {
                onIntent(.openTimerPicker)
            }
            .accessibilityIdentifier("fl.lechef.addTimer")
            FLButton(.primary, state.nextButtonTitle, haptic: .mediumCommit) {
                onIntent(.nextStep(at: Date().timeIntervalSince1970))
            }
            .accessibilityIdentifier("fl.lechef.next")
        }
        .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
        .padding(.vertical, 12)
        .background(Theme.swiftColor(.bg, in: .hob))
    }
}

// MARK: - Progress segments

private struct LeChefProgressSegments: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(state.steps.indices, id: \.self) { index in
                Button {
                    onIntent(.jumpToStep(index: index))
                } label: {
                    Capsule()
                        .fill(
                            index <= state.stepIndex
                                ? Theme.swiftColor(.yolk, in: .hob)
                                : Theme.swiftColor(.rule2, in: .hob)
                        )
                        .frame(height: 6)
                }
                .buttonStyle(FLButtonStyle())
                .accessibilityLabel("Step \(index + 1)")
                .accessibilityAddTraits(index == state.stepIndex ? [.isSelected] : [])
                .accessibilityIdentifier("fl.lechef.progress.\(index + 1)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.lechef.progress")
    }
}

// MARK: - The LeChef panel (proposals)

private struct LeChefProposalPanel: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap / 2)) {
            Text("LeChef")
                .flType(.sectionLabel)
                .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                .accessibilityIdentifier("fl.lechef.panel")

            if let failure = state.mutationFailureLine {
                Text(failure)
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.error, in: .hob))
                    .accessibilityIdentifier("fl.lechef.mutationFailed")
            }

            ForEach(state.proposals) { proposal in
                proposalBlock(proposal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.yolkSoft, in: .hob).opacity(0.35))
        )
        .accessibilityIdentifier("fl.lechef.panelCard")
    }

    @ViewBuilder
    private func proposalBlock(_ proposal: LeChefViewState.Proposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(state.proposalDisplay(proposal).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
            }
            actions(for: proposal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.lechef.proposal.\(proposal.id)")
    }

    @ViewBuilder
    private func actions(for proposal: LeChefViewState.Proposal) -> some View {
        switch proposal.payload {
        case .timerSuggestion(let seconds, _):
            FLButton(.primary, state.timerSuggestionTitle(seconds: seconds), haptic: .lightConfirm) {
                onIntent(.applyTimerSuggestion(id: proposal.id))
            }
            .accessibilityIdentifier("fl.lechef.timerChip")
        case .substitution, .adaptChange:
            if proposal.isApplied {
                Text("Done")
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                    .accessibilityIdentifier("fl.lechef.applied")
            } else if proposal.isAwaitingReceipt {
                // Waiting on the phone: the approval handed the
                // proposal to the authority seam and no receipt has
                // returned. Never shown as success — a receipt is the
                // phone's word, and none has arrived.
                Text("Waiting on the phone…")
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                    .accessibilityIdentifier("fl.lechef.mutationWaiting")
            } else {
                HStack(spacing: 8) {
                    FLButton(.primary, "Approve", haptic: .mediumCommit) {
                        onIntent(.approveProposal(id: proposal.id))
                    }
                    .accessibilityIdentifier("fl.lechef.approve")
                    FLButton(.secondary, "Not now") {
                        onIntent(.declineProposal(id: proposal.id))
                    }
                    .accessibilityIdentifier("fl.lechef.decline")
                }
            }
        case .information, .lookResult, .adaptAnnouncement:
            // Reads apply without ceremony — no action chrome.
            EmptyView()
        }
    }
}

// MARK: - Timers

private struct LeChefTimerStrip: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void

    var body: some View {
        if !state.timers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(state.timers) { timer in
                        FLTimerTile(
                            label: timer.label,
                            remaining: timer.remainingSeconds(at: Date().timeIntervalSince1970),
                            total: timer.totalSeconds,
                            paused: timer.isPaused,
                            onPause: { onIntent(.toggleTimerPause(id: timer.id)) },
                            onRemove: { onIntent(.removeTimer(id: timer.id)) }
                        )
                        .accessibilityIdentifier("fl.lechef.timerTile.\(timer.id)")
                    }
                }
                .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
            }
            .accessibilityIdentifier("fl.lechef.timers")
        }
    }
}

// MARK: - Voice / chat

private struct LeChefVoiceSection: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void

    @State private var chatDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.isTranscriptOn ? "Voice on" : state.voiceOffDisplay)
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
                    .accessibilityIdentifier("fl.lechef.voice")
                Spacer()
                FLButton(.text, state.isTranscriptOn ? "Turn off" : "Turn on") {
                    onIntent(.toggleTranscript)
                }
                .accessibilityIdentifier("fl.lechef.voiceToggle")
            }
            if let hint = state.voiceHintDisplay {
                Text(hint)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                    .accessibilityIdentifier("fl.lechef.voiceHint")
            }
            if state.isTranscriptOn {
                transcript
                HStack(spacing: 8) {
                    TextField(
                        "Ask anything — hands are busy",
                        text: Binding(
                            get: { chatDraft },
                            set: { chatDraft = $0 }
                        )
                    )
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                            .fill(Theme.swiftColor(.bg, in: .hob))
                    )
                    .accessibilityIdentifier("fl.lechef.chatField")
                    .accessibilityLabel("Ask LeChef")
                    FLButton(.secondary, "Send") {
                        onIntent(.sendChat(text: chatDraft))
                        chatDraft = ""
                    }
                    .accessibilityIdentifier("fl.lechef.chatSend")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transcript: some View {
        // The live transcript, last few turns. It exists only while the
        // session is live; leaving or toggling off drops it.
        ForEach(state.transcript.suffix(4)) { turn in
            Text(turn.text)
                .flType(.body)
                .foregroundStyle(
                    turn.speaker == .you
                        ? Theme.swiftColor(.ink, in: .hob)
                        : Theme.swiftColor(.ink2, in: .hob)
                )
                .frame(maxWidth: .infinity, alignment: turn.speaker == .you ? .trailing : .leading)
                .accessibilityIdentifier("fl.lechef.transcriptTurn")
        }
    }
}

// MARK: - The push-to-look overlay

private struct LeChefLookOverlay: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void
    let lookPreview: AnyView?

    var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: .hob).ignoresSafeArea()
            VStack(spacing: CGFloat(Density.deciding.blockGap)) {
                viewfinder
                Text(state.lookCaptionDisplay)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("fl.lechef.lookCaption")
                controls
                if let problem = state.lookProblemDisplay {
                    Text(problem)
                        .flType(.secondary)
                        .foregroundStyle(Theme.swiftColor(.error, in: .hob))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("fl.lechef.lookProblem")
                }
            }
            .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
        }
        .accessibilityIdentifier("fl.lechef.viewfinder")
    }

    @ViewBuilder
    private var viewfinder: some View {
        if let lookPreview {
            lookPreview
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                    .fill(Theme.swiftColor(.yolkSoft, in: .hob).opacity(0.3))
                Text("The host's viewfinder opens here.")
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
            }
            .aspectRatio(3.0 / 2.0, contentMode: .fit)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state.lookStage {
        case .viewfinder:
            HStack(spacing: 12) {
                FLButton(.primary, "Send one frame", haptic: .lightConfirm) {
                    onIntent(.captureLook(.singleFrame))
                }
                .accessibilityIdentifier("fl.lechef.lookFrame")
                FLButton(.secondary, "3-second clip") {
                    onIntent(.captureLook(.clip(seconds: LeChefViewState.LookCapture.maxClipSeconds)))
                }
                .accessibilityIdentifier("fl.lechef.lookClip")
            }
        case .captured:
            HStack(spacing: 12) {
                FLButton(.primary, "Send", haptic: .mediumCommit) {
                    onIntent(.sendLook)
                }
                .accessibilityIdentifier("fl.lechef.lookSend")
                FLButton(.secondary, "Cancel") {
                    onIntent(.cancelLook)
                }
                .accessibilityIdentifier("fl.lechef.lookCancel")
            }
        case .uploading:
            FLEmptyLoadingLine()
                .accessibilityIdentifier("fl.lechef.lookUploading")
        case .failed:
            HStack(spacing: 12) {
                FLButton(.primary, "Try again") {
                    onIntent(.retryLook)
                }
                .accessibilityIdentifier("fl.lechef.lookRetry")
                FLButton(.secondary, "Close") {
                    onIntent(.cancelLook)
                }
                .accessibilityIdentifier("fl.lechef.lookCancel")
            }
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Paused

private struct LeChefPausedSurface: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
            Text("Paused.")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
                .accessibilityIdentifier("fl.lechef.paused.title")
                .accessibilityAddTraits(.isHeader)
            Text("Steps wait. Timers keep their deadlines.")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
                .accessibilityIdentifier("fl.lechef.paused.caption")
            if let progress = state.headerProgressDisplay(at: Date().timeIntervalSince1970) {
                Text(progress)
                    .flType(.sectionLabel)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                    .accessibilityIdentifier("fl.lechef.paused.progress")
            }
            Spacer()
            FLButton(.primary, "Resume cooking", haptic: .mediumCommit) {
                onIntent(.resumeSession)
            }
            .accessibilityIdentifier("fl.lechef.resume")
            FLButton(.secondary, "Cancel this cook") {
                onIntent(.cancelSession)
            }
            .accessibilityIdentifier("fl.lechef.cancelCook")
        }
        .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Complete (the remember surface)

private struct LeChefCompleteSurface: View {
    let state: LeChefViewState
    let onIntent: (LeChefIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap / 2)) {
            Text("Done cooking")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
                .accessibilityIdentifier("fl.lechef.complete.title")
                .accessibilityAddTraits(.isHeader)
            Text(state.completeSubtitle)
                .flType(.secondary)
                .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
                .accessibilityIdentifier("fl.lechef.complete.subtitle")
            if let duration = state.cookedDurationLine {
                Text(duration)
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
                    .accessibilityIdentifier("fl.lechef.duration")
            }

            Text("How was it?")
                .flType(.sectionLabel)
                .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                .accessibilityIdentifier("fl.lechef.rating")
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        onIntent(.setRating(star))
                    } label: {
                        Image(systemName: (state.rating ?? 0) >= star ? "star.fill" : "star")
                            .flType(.cookStep)
                            .foregroundStyle(Theme.swiftColor(.yolk, in: .hob))
                    }
                    .buttonStyle(FLButtonStyle())
                    .accessibilityLabel("Rate \(star) of 5")
                    .accessibilityAddTraits(state.rating == star ? [.isSelected] : [])
                    .accessibilityIdentifier("fl.lechef.rating.star.\(star)")
                }
            }
            .accessibilityElement(children: .contain)

            TextField(
                "One line for next time",
                text: Binding(
                    get: { state.noteDraft ?? "" },
                    set: { onIntent(.editNoteDraft($0)) }
                )
            )
            .flType(.body)
            .foregroundStyle(Theme.swiftColor(.ink, in: .hob))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                    .fill(Theme.swiftColor(.yolkSoft, in: .hob).opacity(0.35))
            )
            .accessibilityIdentifier("fl.lechef.note")

            FLButton(.text, "Say it instead") {
                onIntent(.requestVoiceNote)
            }
            .accessibilityIdentifier("fl.lechef.sayIt")

            Spacer()

            FLButton(.primary, "Save this cook", haptic: .mediumCommit) {
                onIntent(.saveRecord)
            }
            .disabled(state.isSavingRecord)
            .accessibilityIdentifier("fl.lechef.save")
            if state.showsSaveReceipt {
                Text(state.saveReceiptDisplay)
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: .hob))
                    .accessibilityIdentifier("fl.lechef.receipt")
            }
            if state.saveFailed {
                Text("Couldn't save just now — it's all still here. Try again.")
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.error, in: .hob))
                    .accessibilityIdentifier("fl.lechef.saveFailed")
            }
            Text(state.privacyLine)
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                .accessibilityIdentifier("fl.lechef.privacy")
            if let nutrition = state.nutritionLine {
                Text(nutrition)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: .hob))
                    .accessibilityIdentifier("fl.lechef.nutrition")
            }
            FLButton(.secondary, "Done") {
                onIntent(.closeComplete)
            }
            .accessibilityIdentifier("fl.lechef.done")
        }
        .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
