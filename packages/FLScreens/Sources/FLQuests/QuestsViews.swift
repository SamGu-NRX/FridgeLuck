// FLQuests — the SwiftUI screen (CANDIDATE).
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
// Verification needs a Mac or the staged render workflow. See the
// package README and Part 2's TonightViews header for the same caveat.
//
// CANDIDATE (SPEC §2): this screen is a candidate, not a committed cut.
// It is reached only through the candidate flag — the host gates the
// entry row (FLProgressView's "Quests" row) and this module ships behind
// `QuestsViewState.enabled` (default OFF, lint-pinned) so dropping or
// promoting it is a one-line change plus host wiring. Marked again in
// part6-notes.
//
// Craft rules this file encodes (the candidates-quests mock + the
// binding constraints):
// - Every colour through Theme.swiftColor, every type through .flType,
//   every radius through Radius — the screen contains no visual value of
//   its own. The mock's 44 pt mono counter has no token role; the
//   counter value uses the `.dishTitle` role (the system's large data
//   display) and the divergence is recorded in part6-notes.
// - Density: rows lists — `Density.dense`.
// - Privacy by construction (SPEC §3.4): the preview renders ONLY the
//   payload's allowlisted lines — pantry, health-profile, taste and
//   exact-time data are structurally unrenderable here because the
//   state never carries them. The confirm step is the screen's only
//   path to a share event.
// - The join is one primary action; leaving is quiet text, never
//   destructive red. Offline, the join queues and the receipt says so.
// - Done quests hold their counter and swap join controls for the
//   host's done line; rewards are display chips, never points.
// - The host's quest order is the host's statement; rows never re-rank.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

public struct FLQuestsView: View {

    /// The screen's state. The host owns it; the view only dispatches.
    @Binding var state: QuestsViewState
    /// Every tap becomes a typed intent. The view routes nothing itself.
    let onIntent: (QuestsIntent) -> Void

    @Environment(\.flScheme) private var scheme

    public init(state: Binding<QuestsViewState>, onIntent: @escaping (QuestsIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
                    header
                    if state.showsEmpty {
                        emptyState
                    } else if let featured = state.featuredQuest {
                        featuredSection(featured)
                        alsoSection
                        yourWeekSection
                    }
                    if let asOf = state.asOf {
                        Text(asOf)
                            .flType(.evidence)
                            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                            .accessibilityIdentifier("fl.quests.asOf")
                    }
                    if let receipt = state.joinReceipt {
                        Text(receipt)
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                            .accessibilityIdentifier("fl.quests.joinReceipt")
                    }
                    shareSection
                }
                .padding(.horizontal, CGFloat(Density.dense.sideMargin))
                // The family's root rhythm — 16/24, as Parts 2–5 (Part 7
                // audit: these roots sat at 8 with no recorded reason).
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("fl.quests.screen")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quests")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.quests.title")
                .accessibilityAddTraits(.isHeader)
            Text(state.weekCaption)
                .flType(.evidence)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .accessibilityIdentifier("fl.quests.weekCaption")
        }
    }

    private var emptyState: some View {
        Text("Nothing to join this week.")
            .flType(.body)
            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            .accessibilityIdentifier("fl.quests.empty")
    }

    // MARK: Featured quest

    private func featuredSection(_ quest: QuestsViewState.Quest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FLSectionLabel("This week's quest")
                .accessibilityIdentifier("fl.quests.featuredSection")

            VStack(alignment: .leading, spacing: 10) {
                Text(quest.title)
                    .flType(.dishTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.quests.featuredTitle")
                if let brief = quest.brief {
                    Text(brief)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        .accessibilityIdentifier("fl.quests.featuredBrief")
                }
                Text(quest.rulesLine)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.quests.featuredRules")
                Text(quest.cooksDisplay)
                    .flType(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .accessibilityIdentifier("fl.quests.featuredCooks")
                if let chip = quest.rewardChip {
                    FLChip(chip, isSelected: true) {}
                        .accessibilityIdentifier("fl.quests.rewardChip")
                }
                // Done quests hold their counter and swap the join
                // controls for the done line.
                if let doneLine = quest.doneLine {
                    Text(doneLine)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .accessibilityIdentifier("fl.quests.doneLine")
                } else if quest.isJoined {
                    // Leaving is quiet text, never destructive red.
                    FLButton(.text, "Leave") {
                        onIntent(.leave(id: quest.id))
                    }
                    .accessibilityIdentifier("fl.quests.leaveButton")
                } else {
                    FLButton(.primary, "Join", haptic: .mediumCommit) {
                        onIntent(.join(id: quest.id))
                    }
                    .accessibilityIdentifier("fl.quests.joinButton")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // The mock's featured card: page background with a rule
                // border — Tonight's card language, not a new surface.
                RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                    .fill(Theme.swiftColor(.bg, in: scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                            .stroke(Theme.swiftColor(.rule, in: scheme), lineWidth: 1)
                    )
            )
            .accessibilityIdentifier("fl.quests.featuredCard")
        }
    }

    // MARK: Also this week

    private var alsoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("Also this week")
                .accessibilityIdentifier("fl.quests.alsoSection")
            ForEach(state.alsoQuests) { quest in
                FLHairlineRow(haptic: .lightConfirm) {
                    onIntent(.join(id: quest.id))
                } content: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quest.title)
                                .flType(.body)
                                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            Text(quest.rulesLine)
                                .flType(.caption)
                                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        }
                        Spacer(minLength: 8)
                        Text(quest.cooksDisplay)
                            .flType(.evidence)
                            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    }
                }
                .accessibilityIdentifier("fl.quests.questRow.\(quest.id)")
            }
        }
    }

    // MARK: Your week (the host's three counters, verbatim)

    private var yourWeekSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("Your week")
                .accessibilityIdentifier("fl.quests.yourWeekSection")
            HStack(alignment: .top, spacing: 20) {
                counter(value: "\(state.weekCooksMade)", label: "cooks made", id: "fl.quests.cooksMade")
                counter(value: "\(state.weekSwapsUsed)", label: "swaps used", id: "fl.quests.swapsUsed")
                counter(value: state.weekSavedDisplay, label: "food saved", id: "fl.quests.foodSaved")
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("fl.quests.weekCounters")
        }
    }

    private func counter(value: String, label: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .flType(.dishTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            Text(label)
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: The share (preview -> confirm; the only path to a share)

    @ViewBuilder
    private var shareSection: some View {
        if state.sharePreview != nil {
            // The preview shows exactly the payload's allowlisted lines,
            // so what leaves the phone is exactly what was approved.
            VStack(alignment: .leading, spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                FLSectionLabel("Ready to share")
                    .accessibilityIdentifier("fl.quests.sharePreviewSection")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array((state.sharePreview?.previewLines ?? []).enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                        .fill(Theme.swiftColor(.bg, in: scheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                                .stroke(Theme.swiftColor(.rule, in: scheme), lineWidth: 1)
                        )
                )
                .accessibilityIdentifier("fl.quests.sharePreview")

                HStack(spacing: 12) {
                    FLButton(.primary, "Share", haptic: .mediumCommit) {
                        onIntent(.shareConfirmed)
                    }
                    .accessibilityIdentifier("fl.quests.shareConfirm")
                    FLButton(.text, "Cancel") {
                        onIntent(.cancelSharePreview)
                    }
                    .accessibilityIdentifier("fl.quests.shareCancel")
                }
            }
        }
    }
}
#endif
