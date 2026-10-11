// FLTasteProfile — the SwiftUI screen.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds
// this target's state files as Foundation; this file is Apple-gated and
// has never been compiled or rendered by a SwiftUI-capable toolchain.
//
// Craft rules this file encodes (the taste-profile mock + the binding
// constraints):
// - Every colour through Theme.swiftColor, every type through .flType,
//   every radius through Radius — the screen carries no visual value of
//   its own. Dense density throughout (the token doc names taste profile
//   dense).
// - The ledger, not the horoscope: sentences stay in ink; the accent
//   appears only where the mock puts it — selection (chips) and the
//   evidence tag.
// - Evidence and dates are host-verbatim strings; this layer never
//   computes a count, a date, or a percentage.
// - The mock's swipe/menu affordances adapt to context menus (Part 3's
//   convention); nothing is forgotten or removed without an explicit
//   named action. "Don't ask again" lives in the row's context menu —
//   deliberately a different control from Wrong.
// - The forget-everything confirmation is an inline ask-once block with
//   the count, never a system alert; restrictions survive it and the
//   copy says so.
// - NoFLTasteSentence reuse: that component's "N seen" evidence line
//   violates the denominator rule, so rows are built here with the same
//   visual grammar (flagged in docs/screens/part4-notes.md).

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

/// The Taste-profile destination — the on-device learning ledger,
/// reached from profile and setup contexts.
public struct TasteProfileView: View {

    @Binding var state: TasteViewState
    let onIntent: (TasteIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: Binding<TasteViewState>,
        onIntent: @escaping (TasteIntent) -> Void
    ) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(Density.dense.sectionGap ?? 24)) {
                    header
                    if state.isNewUser {
                        newUserBlock
                    } else {
                        sentencesSection
                        restrictionsSection
                        memoriesSection
                        setupSection
                        footer
                    }
                }
                .padding(.horizontal, CGFloat(Density.dense.sideMargin))
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(reduceMotion ? nil : .fl(.fade), value: state.sentences)
        .accessibilityIdentifier("fl.taste.screen")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your taste")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.taste.title")
            if let cooks = state.cooksCountDisplay {
                Text(cooks)
                    .flType(.evidence)
                    .flTracking(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.taste.cooks")
            }
        }
    }

    // MARK: New user

    /// Under three cooks: one sentence instead of the list.
    private var newUserBlock: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
            Text("What I've learned")
                .flType(.sectionLabel)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .accessibilityIdentifier("fl.taste.learnedLabel")
            Text(state.newUserLine ?? "")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.taste.newUser")
            restrictionsSection
            footer
        }
    }

    // MARK: Sentences

    private var sentencesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("What I've learned")
                .accessibilityIdentifier("fl.taste.learnedLabel")
            ForEach(state.sentences) { sentence in
                sentenceRow(sentence)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.taste.sentences")
    }

    private func sentenceRow(_ sentence: TasteViewState.Sentence) -> some View {
        let isRejected = sentence.status == .rejected
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(sentence.text)
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(isRejected ? .ink2 : .ink, in: scheme))
                    .strikethrough(isRejected)
                    .accessibilityIdentifier("fl.taste.sentence.\(sentence.id)")
                Spacer()
                // The evidence tag: the accent's home on this screen.
                Text(sentence.evidenceDisplay)
                    .flType(.evidence)
                    .flTracking(.evidence)
                    .foregroundStyle(Theme.swiftColor(.yolkInk, in: scheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.swiftColor(.yolkSoft, in: scheme))
                    )
                    .accessibilityIdentifier("fl.taste.evidence.\(sentence.id)")
            }

            if isRejected {
                HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                    Text("Won't use this.")
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        .accessibilityIdentifier("fl.taste.rejected.\(sentence.id)")
                    FLChip("Undo") {
                        onIntent(.undoJudgement(sentenceID: sentence.id))
                    }
                    .accessibilityIdentifier("fl.taste.sentenceUndo.\(sentence.id)")
                }
            } else if sentence.status == .confirmed, let line = sentence.confirmationLine {
                Text(line)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.taste.confirmed.\(sentence.id)")
            }

            chips(for: sentence)
        }
        .padding(.vertical, 12)
        .opacity(isRejected ? 0.6 : 1)
        .contextMenu { contextActions(for: sentence) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.taste.sentenceRow.\(sentence.id)")
    }

    @ViewBuilder
    private func chips(for sentence: TasteViewState.Sentence) -> some View {
        switch sentence.kind {
        case .offer:
            HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                if !sentence.offerDeclined {
                    FLChip("Suggest some", isSelected: sentence.status == .confirmed) {
                        onIntent(.answerOffer(sentenceID: sentence.id, suggest: true))
                    }
                    .accessibilityIdentifier("fl.taste.offerSuggest.\(sentence.id)")
                    FLChip("Not interested") {
                        onIntent(.answerOffer(sentenceID: sentence.id, suggest: false))
                    }
                    .accessibilityIdentifier("fl.taste.offerDecline.\(sentence.id)")
                }
                FLChip("Never suggest", isSelected: sentence.promptSuppressed) {
                    onIntent(.neverSuggest(sentenceID: sentence.id))
                }
                .accessibilityIdentifier("fl.taste.offerNever.\(sentence.id)")
            }
        case .pattern:
            HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                FLChip("Right", isSelected: sentence.status == .confirmed) {
                    onIntent(.judge(sentenceID: sentence.id, right: true))
                }
                .accessibilityIdentifier("fl.taste.sentenceRight.\(sentence.id)")
                FLChip("Wrong", isSelected: sentence.status == .rejected) {
                    onIntent(.judge(sentenceID: sentence.id, right: false))
                }
                .accessibilityIdentifier("fl.taste.sentenceWrong.\(sentence.id)")
            }
        }
    }

    @ViewBuilder
    private func contextActions(for sentence: TasteViewState.Sentence) -> some View {
        // "Don't ask again" is a different control from Wrong: it lives
        // here, stops future prompts, and never touches the record.
        if !sentence.promptSuppressed {
            Button("Don't ask again about this") {
                onIntent(.dontAskAgain(sentenceID: sentence.id))
            }
        }
    }

    // MARK: Restrictions

    /// The hard filters. No section header (the mock shows the chips
    /// directly); locked chips carry their setup note and cannot be
    /// removed here — the wrap grid adapts chip widths.
    private var restrictionsSection: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.dense.chipGap ?? 8)) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: CGFloat(Density.dense.chipGap ?? 8))],
                spacing: CGFloat(Density.dense.chipGap ?? 8)
            ) {
                ForEach(state.restrictions) { restriction in
                    restrictionChip(restriction)
                }
                addRestrictionChip
            }
            if state.saveFailed {
                Text("Couldn't save. Changes kept — try again.")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.error, in: scheme))
                    .accessibilityIdentifier("fl.taste.saveError")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.taste.restrictions")
    }

    private func restrictionChip(_ restriction: TasteViewState.Restriction) -> some View {
        Group {
            if restriction.isLocked {
                FLChip(restriction.setupNote.map { restriction.name + " · " + $0 } ?? restriction.name)
                    .accessibilityHint("Set in setup. Edited there, never here.")
            } else {
                FLChip(restriction.name) { }
                    .contextMenu {
                        Button("Remove restriction") {
                            onIntent(.removeRestriction(id: restriction.id))
                        }
                    }
            }
        }
        .accessibilityIdentifier("fl.taste.restriction.\(restriction.id)")
    }

    @State private var isAddingRestriction = false
    @State private var restrictionDraft = ""

    private var addRestrictionChip: some View {
        Group {
            if isAddingRestriction {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Restriction name", text: $restrictionDraft)
                        .textFieldStyle(.plain)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                                .fill(Theme.swiftColor(.pillGone, in: scheme))
                        )
                        .accessibilityIdentifier("fl.taste.restrictionField")
                    FLChip("Add restriction") {
                        onIntent(.addRestriction(name: restrictionDraft))
                        restrictionDraft = ""
                        isAddingRestriction = false
                    }
                    .accessibilityIdentifier("fl.taste.restrictionAddApply")
                }
            } else {
                FLChip("Add") {
                    isAddingRestriction = true
                }
                .accessibilityIdentifier("fl.taste.restrictionAdd")
            }
        }
    }

    // MARK: Memories

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                FLSectionLabel("LeChef remembers")
                    .accessibilityIdentifier("fl.taste.memoriesLabel")
                Spacer()
                Text(state.memoriesCountDisplay)
                    .flType(.evidence)
                    .flTracking(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.taste.memoriesCount")
            }
            ForEach(Array(state.memories.enumerated()), id: \.element.id) { index, memory in
                // The forget receipt splices in at the note's former
                // place — changing your mind never requires a reset.
                if state.lastForgotten?.previousIndex == index {
                    forgetReceipt
                }
                memoryRow(memory)
            }
            if state.memories.isEmpty, state.lastForgotten == nil {
                Text("Nothing remembered yet.")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.taste.memoriesEmpty")
            } else if state.memories.isEmpty, state.lastForgotten != nil {
                forgetReceipt
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.taste.memories")
    }

    private func memoryRow(_ memory: TasteViewState.Memory) -> some View {
        FLHairlineRow {
            VStack(alignment: .leading, spacing: 2) {
                if let dish = memory.dishName {
                    Text(dish)
                        .flType(.secondary)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        .accessibilityIdentifier("fl.taste.memoryDish.\(memory.id)")
                }
                Text(memory.text)
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.taste.memory.\(memory.id)")
            }
        }
        .contextMenu {
            Button("Forget this note") {
                onIntent(.forgetMemory(id: memory.id))
            }
        }
        .accessibilityValue(memory.dateDisplay)
        .accessibilityIdentifier("fl.taste.memoryRow.\(memory.id)")
    }

    private var forgetReceipt: some View {
        HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
            Text("Forgotten.")
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .accessibilityIdentifier("fl.taste.forgetReceipt")
            FLChip("Undo") {
                onIntent(.undoForget)
            }
            .accessibilityIdentifier("fl.taste.forgetUndo")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    // MARK: Setup summary

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                FLSectionLabel("What you told me at setup")
                    .accessibilityIdentifier("fl.taste.setupLabel")
                Spacer()
                FLButton(.text, "Edit") {
                    onIntent(.editSetup)
                }
                .accessibilityIdentifier("fl.taste.setupEdit")
            }
            FLHairlineRow {
                Text(state.setupSummary.joined(separator: " · "))
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            }
            .accessibilityIdentifier("fl.taste.setupSummary")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.taste.setup")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.hasUnsavedChanges {
                Text("Changes not saved yet.")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.taste.savePending")
            }
            if state.isConfirmingForgetAll {
                // The ask-once confirmation, with the count of what will
                // be deleted and what survives.
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.forgetAllPromptDisplay)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .accessibilityIdentifier("fl.taste.forgetAllPrompt")
                    HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                        FLChip("Forget everything") {
                            onIntent(.forgetEverything)
                        }
                        .accessibilityIdentifier("fl.taste.forgetAllConfirm")
                        FLChip("Keep everything") {
                            onIntent(.cancelForgetAll)
                        }
                        .accessibilityIdentifier("fl.taste.forgetAllCancel")
                    }
                }
                .accessibilityElement(children: .contain)
            }
            Button {
                onIntent(.exportTaste)
            } label: {
                Text("Export everything I know about you")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            }
            .accessibilityIdentifier("fl.taste.export")
            Button {
                onIntent(.askForgetAll)
            } label: {
                Text("Forget everything")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.error, in: scheme))
            }
            .accessibilityIdentifier("fl.taste.forgetAll")
        }
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fl.taste.footer")
    }
}
#endif
