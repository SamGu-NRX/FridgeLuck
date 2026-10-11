// FLTour — the SwiftUI screen (CANDIDATE).
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
// Verification needs a Mac or the staged render workflow. See the
// package README and Part 2's TonightViews header for the same caveat.
//
// CANDIDATE (SPEC §2): the constrained onboarding tour is a candidate,
// not a committed cut. It ships behind `TourViewState.enabled` (default
// OFF, lint-pinned) so dropping or promoting it is a one-line change
// plus host wiring. Marked again in part6-notes.
//
// Craft rules this file encodes (the candidates-tour mock + the binding
// constraints):
// - The tour is a modal card over dimmed content — never a takeover:
//   the host's screens stay visible behind the backdrop, Skip is always
//   visible, and one tap outside the card dismisses. Dismissal is one
//   tap, always.
// - The state machine's auto-return is authoritative: while the stage
//   is `.presenting` the card stands; `.returnedHome`, `.idle`,
//   `.dismissed` and `.completed` render nothing — the card is DOWN and
//   the app is usable. The view owns no timers and no auto-advance.
// - Back is absent on the first step (the state refuses `.back` there
//   anyway; the affordance never shows a lie).
// - The primary action is the step's own host-verbatim label; on the
//   last step it still reads that label — the tour promises, it does
//   not cheer.
// - Every colour through Theme.swiftColor, every type through .flType,
//   every radius through Radius; Density.deciding — the tour is a
//   decision surface, not a dense list.
// - The photo is the shared 3:2 area capped at 40% (PhotoLayoutRule);
//   the package ships the AREA and its caption, the host supplies the
//   imagery.
// - No count-up, no bounce: motion is the system fade token, dropped
//   under Reduce Motion.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

public struct FLTourView: View {

    /// The screen's state. The host owns it; the view only dispatches.
    @Binding var state: TourViewState
    /// Every tap becomes a typed intent. The view routes nothing itself.
    let onIntent: (TourIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: Binding<TourViewState>, onIntent: @escaping (TourIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        // The auto-return contract: while the card is down (returned
        // home, dismissed, completed, never started) the view renders
        // nothing and the host's screen is the whole experience.
        if state.isPresenting, let step = state.currentStep {
            ZStack {
                // The dimmed backdrop: the host's screen stays visible
                // and one tap outside the card dismisses the tour. The
                // palette is a closed set with no scrim role, so the
                // dim is the theme's own ink at a reduced opacity — an
                // opacity, never a new colour value; a dedicated scrim
                // role belongs to a design-table revision.
                Theme.swiftColor(.ink, in: scheme)
                    .opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { onIntent(.skip) }
                    .accessibilityIdentifier("fl.tour.backdrop")
                    .accessibilityHidden(true)

                card(step)
                    .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
                    .animation(reduceMotion ? nil : .fl(.fade), value: state.currentIndex)
            }
            .accessibilityIdentifier("fl.tour.screen")
        }
    }

    // MARK: The card

    private func card(_ step: TourViewState.Step) -> some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
            if let photoCaption = step.photoCaption {
                photoArea(caption: photoCaption)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let pager = state.pagerLine {
                    Text(pager)
                        .flType(.evidence)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        .accessibilityIdentifier("fl.tour.pager")
                }
                Text(step.title)
                    .flType(.screenTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.tour.stepTitle")
                    .accessibilityAddTraits(.isHeader)
                Text(step.bodyText)
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.tour.stepBody")
            }

            fitBlock(step)
            privacyBlock(step)
            controls(step)
        }
        // The family's card padding — the same 16 the pick, featured,
        // challenge and cook cards use (Part 7 audit: this card alone
        // sat at 20).
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.bg, in: scheme))
        )
        .accessibilityIdentifier("fl.tour.card")
    }

    // MARK: Photo (the shared 3:2 rule, one hero derivation)

    /// The same single derivation every screen-top hero makes
    /// (`PhotoLayoutRule.heroIdealHeight`) — Part 7 audit: the earlier
    /// pattern re-derived the height inside the area's own frame and
    /// double-capped; the tour card's photo now matches Tonight's.
    private func photoArea(caption: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.rule, in: scheme))
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                Text(caption)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(height: CGFloat(PhotoLayoutRule.heroIdealHeight), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("fl.tour.photo")
    }

    // MARK: The fit promise (the first step's meter starting at zero)

    @ViewBuilder
    private func fitBlock(_ step: TourViewState.Step) -> some View {
        if let fitLine = step.fitLine {
            VStack(alignment: .leading, spacing: 4) {
                if let have = step.fitHave, let total = step.fitTotal {
                    // The meter is the count: have of total, in the
                    // mono role — a fact, never a score.
                    Text("\(have) of \(total)")
                        .flType(.quantity)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .accessibilityIdentifier("fl.tour.fitCount")
                }
                Text(fitLine)
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.tour.fitLine")
            }
            .accessibilityIdentifier("fl.tour.fitBlock")
        }
    }

    // MARK: The privacy promises (what stays on the phone, what is undoable)

    @ViewBuilder
    private func privacyBlock(_ step: TourViewState.Step) -> some View {
        if !step.privacyLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(step.privacyLines.enumerated()), id: \.offset) { pair in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock")
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                        Text(pair.element)
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    }
                    .accessibilityIdentifier("fl.tour.privacyLine.\(pair.offset)")
                }
            }
            .accessibilityIdentifier("fl.tour.privacyBlock")
        }
    }

    // MARK: Controls (Skip always visible; Back absent on the first step)

    private func controls(_ step: TourViewState.Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let index = state.currentIndex, index > 0 {
                    FLButton(.text, "Back") {
                        onIntent(.back)
                    }
                    .accessibilityIdentifier("fl.tour.back")
                }

                Spacer(minLength: 8)

                // Dismissal is one tap, always visible.
                FLButton(.text, "Skip") {
                    onIntent(.skip)
                }
                .accessibilityIdentifier("fl.tour.skip")

                // The primary action is the step's own promise, host-
                // verbatim. CompleteStep auto-returns (or completes) —
                // that is the state's decision, never a view timer.
                FLButton(.primary, step.primaryLabel, haptic: .lightConfirm) {
                    onIntent(.completeStep)
                }
                .accessibilityIdentifier("fl.tour.primary")
            }

            if let footer = state.footerCaption {
                Text(footer)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .accessibilityIdentifier("fl.tour.footer")
            }
        }
    }
}
#endif
