// FLTonight — the SwiftUI screen.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target as an empty module; nothing here has ever been compiled or
// rendered by a SwiftUI-capable toolchain. Verification needs a Mac or the
// staged render workflow (ci/pending-workflows/screens-renders.yml — HELD,
// not installed). See the package README.
//
// Craft rules this file encodes (SPEC 2/3 + Direction H's state notes):
// - Deciding density: one thing per screenful; sideMargin/blockGap/action
//   clearance all read from Density.deciding — never literals.
// - Every colour through Theme.swiftColor, every type through .flType,
//   every radius through Radius — the screen contains no visual value.
// - Motion by frequency: the pick swap is a REJECTION response — no
//   animation (SPEC 2). The constraints offer appears with fade (0.15 s).
//   Reduce Motion turns even those into the 150 ms reduced fade.
// - Targets: primary/secondary actions ride FLButton's 48 pt clearance;
//   text-kind actions are wrapped to a 44 pt minimum.
// - The hero copy asks the taste question AT THE DECISION, once.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

public struct TonightView: View {

    /// The screen's state. The host owns it; the view only dispatches.
    @Binding var state: TonightViewState
    /// Every tap becomes a typed intent. The view routes nothing itself.
    let onIntent: (TonightIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Presentation-only: the servings editor disclosure.
    @State private var servingsEditorShown = false

    public init(state: Binding<TonightViewState>, onIntent: @escaping (TonightIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
                    header
                    content
                    useSoonBlock
                    actions
                }
                .padding(.horizontal, CGFloat(Density.deciding.sideMargin))
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            // The pick swap answers "Something else": no animation, no
            // reward (SPEC 2).
            .animation(reduceMotion ? nil : .fl(.none), value: state.content)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.dateLabel)
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.tonight.date")
                .accessibilityAddTraits(.isHeader)
            if let asOf = state.pickAsOf {
                Text(asOf)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .accessibilityIdentifier("fl.tonight.pickAsOf")
            }
            if state.lateLinesLoading {
                FLEmptyLoadingLine()
                    .accessibilityIdentifier("fl.tonight.lateLines")
            }
        }
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        switch state.content {
        case .unknownKitchen(let reason, let example):
            unknownKitchen(reason: reason, example: example)
        case .pick(let pick):
            pickCard(pick)
        case .sparse(let pick, let youdNeed):
            VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
                pickCard(pick)
                // The "You'd need" list is the bill's shortfall detail; a
                // pending bill (servings changed) withdraws it with the
                // claim until the host recalculates.
                if pick.fitStanding == .current {
                    Text("You'd need: \(youdNeed.joined(separator: ", "))")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        .accessibilityIdentifier("fl.tonight.youdNeed")
                }
            }
        case .nothingFeasible(let pick):
            VStack(alignment: .leading, spacing: CGFloat(Density.deciding.blockGap)) {
                Text("Nothing quite makes it tonight. The closest:")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.tonight.nothingFeasible")
                pickCard(pick)
            }
        }
    }

    /// The hero card: photo (3:2, capped at 40% of the available height),
    /// title, meta, the honest fit line, and the why row.
    private func pickCard(_ pick: TonightViewState.Pick) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            photoArea(pick.photo)
            HStack(alignment: .firstTextBaseline) {
                Text(pick.title)
                    .flType(.dishTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .lineLimit(3)
                    .accessibilityIdentifier("fl.tonight.title")
            }
            HStack {
                Text(pick.meta.display)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.tonight.meta")
                Spacer()
                servingsControl(servings: pick.meta.servings)
            }
            fitBlock(pick)
            if let why = pick.why {
                Button {
                    onIntent(.openWhy)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("“\(why.text)”")
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            .multilineTextAlignment(.leading)
                        Text("Why this?")
                            .flType(.secondary)
                            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("fl.tonight.why")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.bg, in: scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .stroke(Theme.swiftColor(.rule, in: scheme), lineWidth: 1)
        )
        .accessibilityIdentifier("fl.tonight.card")
    }

    /// The photo area: 3:2 by the shared rule, via the ONE derivation
    /// (`PhotoLayoutRule.heroIdealHeight`) — 3:2 at the reference width,
    /// capped once at 40% of the reference screen height so the actions
    /// stay above the tab bar on first paint. Part 7 audit: the earlier
    /// pattern re-derived the height inside the area's own frame and
    /// double-capped (40% of the already-ideal height); every hero now
    /// makes the same single call. The package ships the AREA and its
    /// caption; the host supplies the imagery.
    private func photoArea(_ spec: TonightViewState.PhotoSpec) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.rule, in: scheme))
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                Text(spec.caption)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(height: CGFloat(PhotoLayoutRule.heroIdealHeight), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("fl.tonight.photo")
    }

    /// The honest fit line: the meter is the count, the sentence is the
    /// story. The meter never shows for a state without a real count —
    /// and never while a servings change holds the bill pending: the
    /// claim is withdrawn, so only the recalculation line shows.
    private func fitBlock(_ pick: TonightViewState.Pick) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pick.fitDisplay)
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.tonight.fit")
            if pick.fitStanding == .current {
                FLFitMeter(
                    have: pick.fit.sufficientCount,
                    total: pick.fit.lines.count,
                    swaps: pick.fit.completingSwapCount
                )
            }
        }
    }

    private func servingsControl(servings: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .fl(.fade)) { servingsEditorShown.toggle() }
        } label: {
            Text("\(servings) servings")
                .flType(.quantity)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Adjust servings")
        .accessibilityIdentifier("fl.tonight.servings")
        .sheet(isPresented: $servingsEditorShown) {
            servingsSheet(servings: servings)
                .flScheme(scheme)
        }
    }

    private func servingsSheet(servings: Int) -> some View {
        VStack(spacing: 24) {
            Text("Servings")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            HStack(spacing: 32) {
                Button {
                    onIntent(.setServings(servings - 1))
                } label: {
                    Image(systemName: "minus")
                        .imageScale(.large)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("fl.tonight.servingsMinus")
                Text("\(servings)")
                    .flType(.screenTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.tonight.servingsValue")
                Button {
                    onIntent(.setServings(servings + 1))
                } label: {
                    Image(systemName: "plus")
                        .imageScale(.large)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("fl.tonight.servingsPlus")
            }
            FLButton(.secondary, "Done") { servingsEditorShown = false }
        }
        .padding(CGFloat(Density.deciding.sideMargin))
        .presentationDetents([.height(240)])
        .background(Theme.swiftColor(.bg, in: scheme))
    }

    // MARK: Use soon

    @ViewBuilder
    private var useSoonBlock: some View {
        if !state.useSoon.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FLSectionLabel("Use soon")
                ForEach(state.useSoon) { item in
                    Button {
                        onIntent(.openUseSoon(itemID: item.id))
                    } label: {
                        HStack {
                            Text(item.name)
                                .flType(.body)
                                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            Spacer()
                            Text(item.tag)
                                .flType(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.swiftColor(.yolkSoft, in: scheme)))
                                .foregroundStyle(Theme.swiftColor(.yolkInk, in: scheme))
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("fl.tonight.useSoon.\(item.id)")
                }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A cook in progress replaces the hero with a resume bar. The
            // state field is `activeCook` (CookResume); the view previously
            // read a `resumeDraft` that never existed.
            if let resume = state.activeCook {
                Button {
                    onIntent(.resumeCook)
                } label: {
                    HStack {
                        Image(systemName: "timer")
                        Text("Resume cooking: \(resume.dish)")
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.yolkInk, in: scheme))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: CGFloat(Density.deciding.actionClearance ?? 48))
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                            .fill(Theme.swiftColor(.yolkSoft, in: scheme))
                    )
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("fl.tonight.resumeCook")
            }

            // The actions render the state's primaryAction contract
            // verbatim — the view never keys a cook claim off
            // `carriedPick` (an unknown-kitchen example is a carried pick
            // and earns no cook), and no state is offered an action its
            // knowledge doesn't back.
            switch state.primaryAction {
            case .cookThis:
                cookButton(enabled: true)
            case .cookPendingRecalc:
                // The bill is out for recalculation: the cook is
                // disabled, and the fit line above explains why.
                cookButton(enabled: false)
            case .cookWithSwaps(let count):
                FLButton(
                    .primary,
                    "Cook with \(count) \(count == 1 ? "swap" : "swaps")",
                    haptic: .mediumCommit
                ) {
                    onIntent(.cookThis)
                }
                .accessibilityIdentifier("fl.tonight.cookThis")
            case .shoppingList:
                // Sparse: what the state knows is what you'd need.
                FLButton(.primary, "Shopping list") {
                    onIntent(.shoppingList)
                }
                .accessibilityIdentifier("fl.tonight.shoppingList")
            case .enterKitchen:
                // The kitchen is unknown: the two entry actions rank
                // equal, 44 pt or taller, side by side (never stacked
                // favourites), and no cook claim is offered.
                HStack(spacing: 12) {
                    FLButton(.secondary, "Scan groceries") {
                        onIntent(.scanKitchen)
                    }
                    .accessibilityIdentifier("fl.tonight.scanKitchen")
                    FLButton(.secondary, "Add by name") {
                        onIntent(.enterManually)
                    }
                    .accessibilityIdentifier("fl.tonight.enterManually")
                }
            }

            // SPEC 2: "never taken away" — bound to the state's promise
            // so no decision state can quietly lose it.
            if state.canChooseTomorrow {
                FLButton(.secondary, "Choose tomorrow") {
                    onIntent(.chooseTomorrow)
                }
                .accessibilityIdentifier("fl.tonight.chooseTomorrow")
            }

            if state.carriedPick != nil {
                FLButton(.text, "Something else") {
                    onIntent(.somethingElse)
                }
                .frame(minHeight: 44, alignment: .center)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("fl.tonight.somethingElse")
            }

            if state.constraintsOffered {
                constraintsOffer
            }
            if let question = state.tasteQuestion {
                tasteQuestionRow(question)
            }
        }
    }

    /// The unconditional cook, renderable only where the state's contract
    /// allows it. Disabled while the bill is out for recalculation: the
    /// button keeps its label, the claim is withdrawn, and the hint says
    /// why.
    private func cookButton(enabled: Bool) -> some View {
        FLButton(.primary, "Cook this", haptic: .mediumCommit) {
            onIntent(.cookThis)
        }
        .disabled(!enabled)
        .accessibilityIdentifier("fl.tonight.cookThis")
        .accessibilityHint(enabled ? "" : "Servings changed — waiting for a recalculated fit")
    }

    /// After the third "Something else" — and never before — the four
    /// constraint choices appear (SPEC 2).
    private var constraintsOffer: some View {
        VStack(alignment: .leading, spacing: 8) {
            FLSectionLabel("What would help?")
            HStack(spacing: 8) {
                ForEach(TonightConstraint.allCases, id: \.self) { constraint in
                    FLChip(constraint.label) {
                        onIntent(.chooseConstraint(constraint))
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("fl.tonight.constraint.\(constraint.rawValue)")
                }
            }
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        .animation(.fl(.fade), value: state.constraintsOffered)
        .accessibilityIdentifier("fl.tonight.constraints")
    }

    private func tasteQuestionRow(_ question: TonightViewState.TasteQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.text)
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            HStack(spacing: 16) {
                Button {
                    onIntent(.answerTasteQuestion(questionID: question.id, stop: true))
                } label: {
                    Text("Stop suggesting it")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("fl.tonight.tasteStop")
                Button {
                    onIntent(.answerTasteQuestion(questionID: question.id, stop: false))
                } label: {
                    Text("Keep it")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("fl.tonight.tasteKeep")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.yolkSoft, in: scheme))
        )
        .accessibilityIdentifier("fl.tonight.tasteQuestion")
    }

    // MARK: Unknown kitchen

    private func unknownKitchen(reason: TonightViewState.UnknownReason, example: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reason.headline)
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.tonight.unknownHeadline")
                .accessibilityAddTraits(.isHeader)
            Text("Tell FridgeLuck what's in your kitchen and tonight answers itself. A 30-second shelf scan is enough to start.")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            if let example {
                Text(example)
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.tonight.unknownExample")
            }
        }
    }
}
#endif
