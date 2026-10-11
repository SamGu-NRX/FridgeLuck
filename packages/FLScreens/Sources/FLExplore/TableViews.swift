// FLExplore — the Table screen's SwiftUI views.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
//
// Craft rules this file encodes (the Table mock + the binding constraints):
// - Density: the token doc names the table a dense screen — `Density.dense`
//   throughout.
// - Cards in time order, no ranking furniture anywhere in the layout.
// - Every card ends with the viewer's OWN fit meter and one button; the
//   viewer's own cook renders without a button.
// - Photos: the binding rule frames photos 3:2 (FLCookCard's fixed 1:1
//   frame cannot carry that rule, so the card here composes the same
//   primitives — quote device, FLFitMeter, FLButton, Radius.card — around
//   a PhotoLayoutRule frame; adopting FLCookCard wholesale needs the
//   component to take the layout rule, a base-branch change).
// - Share preview before any share: the sheet shows exactly the frozen
//   preview fields, plus "Nothing else leaves your phone."
// - Challenge renders quietly; entries reward cooks made and food saved.
// - Notes hide offline (asOf set); cards, fits and the challenge stay.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

public struct TableView: View {

    @Binding var state: TableViewState
    let onIntent: (TableIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: Binding<TableViewState>, onIntent: @escaping (TableIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
                    header
                    if let summary = state.weekSummary {
                        Text(summary)
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                            .accessibilityIdentifier("fl.table.weekSummary")
                    }
                    if state.isFetching {
                        FLEmptyLoadingLine().accessibilityIdentifier("fl.table.loading")
                    }
                    content
                }
                .padding(.horizontal, CGFloat(Density.dense.sideMargin))
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(reduceMotion ? nil : .fl(.fade), value: state.phase)
        }
        .sheet(isPresented: shareBinding) {
            SharePreviewSheet(
                preview: state.sharePreview,
                onConfirm: { if let id = state.sharePreview?.cookID { onIntent(.confirmShare(cookID: id)) } },
                onDismiss: { onIntent(.dismissSharePreview) }
            )
            .flScheme(scheme)
        }
        .accessibilityIdentifier("fl.table.screen")
    }

    private var shareBinding: Binding<Bool> {
        Binding(get: { state.sharePreview != nil }, set: { shown in
            if !shown { onIntent(.dismissSharePreview) }
        })
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        switch state.phase {
        case .noTable:
            VStack(alignment: .leading, spacing: 12) {
                Text("Cook with people you eat with")
                    .flType(.screenTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.table.title")
                Text("A table is 2 to 8 people who share what they actually cooked. No likes, no followers — just dishes, notes and what worked.")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                HStack(spacing: 12) {
                    FLButton(.primary, "Start a table", haptic: .lightConfirm) {
                        onIntent(.startTable)
                    }
                    .accessibilityIdentifier("fl.table.start")
                    FLButton(.secondary, "Join with a code") {
                        onIntent(.joinWithCode)
                    }
                    .accessibilityIdentifier("fl.table.join")
                }
            }
        case .active, .fetchFailed:
            VStack(alignment: .leading, spacing: 4) {
                Text(state.tableName ?? "Your table")
                    .flType(.screenTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.table.title")
                if let subtitle = state.subtitleDisplay {
                    Text(subtitle)
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                        .accessibilityIdentifier("fl.table.subtitle")
                }
                if let asOf = state.asOf {
                    Text(asOf)
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                        .accessibilityIdentifier("fl.table.asOf")
                }
                FLButton(.secondary, "Invite", haptic: .lightConfirm) {
                    onIntent(.invite)
                }
                .accessibilityIdentifier("fl.table.invite")
            }
        }
    }

    // MARK: Content by phase

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .noTable:
            notesSection
        case .active:
            if state.viewerIsAlone {
                inviteRow
            }
            if let challenge = state.challenge {
                challengeCard(challenge)
            }
            ForEach(state.cooks) { cook in
                cookCard(cook)
            }
            if state.cooks.isEmpty, state.weekSummary == nil {
                FLEmptyLoadingLine(isLoading: false)
                Text("Nobody's cooked this week yet.")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            }
            notesSection
        case .fetchFailed:
            if state.cooks.isEmpty {
                Text("The table didn't load. Your cooks are safe on this phone.")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.table.offline")
            }
            ForEach(state.cooks) { cook in
                cookCard(cook) // cached cards render instantly in every phase
            }
            Button("Retry") { onIntent(.retryFetch) }
                .flType(.secondary)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("fl.table.retry")
        }
    }

    private var inviteRow: some View {
        FLHairlineRow {
            onIntent(.invite)
        } content: {
            Text("Invite someone. Tables work from 2.")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
        }
        .accessibilityIdentifier("fl.table.inviteRow")
    }

    // MARK: Cards

    private func cookCard(_ cook: TableViewState.Cook) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if cook.photoCaption != nil {
                photoArea
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(cook.dishTitle)
                    .flType(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .lineLimit(1)
                Text("\(cook.cookName) · \(cook.whenDisplay)")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                if let note = cook.note {
                    // The quote device, as FLCookCard renders it.
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(Theme.swiftColor(.ink, in: scheme))
                            .frame(width: 2)
                        Text(note)
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Note: \(note)")
                }
                if let rate = cook.rateDisplay {
                    Text(rate)
                        .flType(.fitCount)
                        .flTracking(.fitCount)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                }
                FLFitMeter(
                    have: cook.fit.have, total: cook.fit.total,
                    swaps: cook.fit.swapsNeeded > 0 ? cook.fit.swapsNeeded : nil
                )
                if let title = cook.buttonTitle {
                    FLButton(
                        cook.buttonIsPrimary ? .primary : .secondary,
                        title,
                        haptic: cook.buttonIsPrimary ? .mediumCommit : nil
                    ) {
                        onIntent(.cookTonight(cookID: cook.id))
                    }
                    .accessibilityIdentifier("fl.table.cardButton.\(cook.id)")
                } else {
                    Text("Your cook")
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                }
                Button("Share") { onIntent(.showSharePreview(cookID: cook.id)) }
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("fl.table.share.\(cook.id)")
            }
            .padding(16)
        }
        .background(Theme.swiftColor(.bg, in: scheme))
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .stroke(Theme.swiftColor(.rule, in: scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous))
        .accessibilityIdentifier("fl.table.card.\(cook.id)")
    }

    /// The 1:1→3:2 photo area: 3:2 by the shared binding rule.
    private var photoArea: some View {
        GeometryReader { geo in
            let height = PhotoLayoutRule.height(
                forWidth: Double(geo.size.width),
                availableHeight: Double(geo.size.height)
            )
            RoundedRectangle(cornerRadius: CGFloat(Radius.row.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.rule, in: scheme))
                .frame(height: CGFloat(height), alignment: .top)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 160) // 3:2 within the card's inner width; cap inside
        .accessibilityHidden(true)
    }

    // MARK: Challenge

    private func challengeCard(_ challenge: TableViewState.Challenge) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(challenge.title)
                .flType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.table.challengeTitle")
            Text(challenge.detailDisplay)
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
            FLButton(.text, challenge.actionTitle) {
                onIntent(.joinChallenge)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("fl.table.challengeJoin")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(Radius.card.rawValue), style: .continuous)
                .stroke(Theme.swiftColor(.rule2, in: scheme), lineWidth: 1)
        )
        .accessibilityIdentifier("fl.table.challenge")
    }

    // MARK: Notes

    @ViewBuilder
    private var notesSection: some View {
        if state.showsNotes, !state.notes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                FLSectionLabel("Notes on recipes you've cooked")
                    .accessibilityIdentifier("fl.table.notesLabel")
                ForEach(state.notes) { note in
                    FLHairlineRow(haptic: .lightConfirm) {
                        onIntent(.openRecipe(recipeID: note.id))
                    } content: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.dish)
                                .flType(.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            Text(note.noteLine)
                                .flType(.body)
                                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                            if let cooks = note.cooksDisplay {
                                Text(cooks)
                                    .flType(.caption)
                                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                            }
                        }
                    }
                    .accessibilityIdentifier("fl.table.note.\(note.id)")
                }
            }
        }
    }
}

/// The share preview: exactly what leaves the phone, then the choice.
private struct SharePreviewSheet: View {

    let preview: TableViewState.SharePreview?
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @Environment(\.flScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
            Text("Sharing to your table")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.table.shareTitle")
            if let preview {
                VStack(alignment: .leading, spacing: 8) {
                    previewRow("Recipe", preview.recipeDisplay)
                    previewRow("Servings", preview.servingsDisplay)
                    if let swaps = preview.swapsDisplay { previewRow("Swaps", swaps) }
                    if let rating = preview.ratingDisplay { previewRow("Rating", rating) }
                    if let note = preview.noteDisplay { previewRow("Note", note) }
                }
                .accessibilityIdentifier("fl.table.shareFields")
                Text("Nothing else leaves your phone — not your pantry, health or taste data, and no exact times.")
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .accessibilityIdentifier("fl.table.sharePrivacy")
            }
            Spacer()
            FLButton(.primary, "Share", haptic: .lightConfirm) { onConfirm() }
                .accessibilityIdentifier("fl.table.shareConfirm")
            FLButton(.secondary, "Keep editing") { onDismiss() }
                .accessibilityIdentifier("fl.table.shareCancel")
        }
        .padding(CGFloat(Density.dense.sideMargin))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.swiftColor(.bg, in: scheme).ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }

    private func previewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .flType(.secondary)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            Spacer()
            Text(value)
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
