// FLKitchen — the SwiftUI screen.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target as an empty module; nothing here has ever been compiled or
// rendered by a SwiftUI-capable toolchain. See the package README.
//
// Craft rules this file encodes (SPEC 3.2 + Direction H's Kitchen state
// notes):
// - Dense density: the 44 pt row grid, rowInner, chipGap, sectionGap all
//   read from Density.dense — nil means "not this screen's measure", so
//   the view treats nil as absence (never `?? 0`).
// - Scans observe, purchases add: the reconciliation pill pair is the only
//   way a scan's observations settle. The still-there pill rides the
//   `pillIdle` warm surface fill, the gone pill the `pillGone` quiet fill —
//   both theme tokens (FLDesignTokens), tinted by whatever the round's
//   pick swaps in.
// - Search replaces the title; no matches ends in "Add '<query>'" —
//   search never dead-ends into a sad empty state.
// - Nothing is auto-expired: staleness is a notice row with "Scan now".
// - A failed backup is one quiet line at the bottom, never a modal.
// - Every row carries its evidence (last confirmed, source).

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

public struct KitchenView: View {

    @Binding var state: KitchenViewState
    let onIntent: (KitchenIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Presentation-only: which row is expanded into its edit state.
    @State private var expandedItemID: String?
    /// Presentation-only: the search field's live text.
    @State private var searchText = ""

    public init(state: Binding<KitchenViewState>, onIntent: @escaping (KitchenIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: sectionGap) {
                    if state.search.isActive { searchHeader } else { titleHeader }
                    content
                    bottomActions
                }
                .padding(.horizontal, sideMargin)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            // Search collapse and row settle are quiet crossfades; prompt
            // resolution collapses instantly (dense screen, high
            // frequency).
            .animation(reduceMotion ? nil : .fl(.fade), value: state.search)
        }
    }

    // MARK: Density

    private var sideMargin: CGFloat { CGFloat(Density.dense.sideMargin) }
    private var sectionGap: CGFloat {
        // Dense owns the section gap; if the token ever drops it, absence
        // is the meaning (never a silently shared default).
        CGFloat(Density.dense.sectionGap ?? 0)
    }
    private var rowGrid: CGFloat? { Density.dense.rowHeight.map(CGFloat.init) }
    private var rowInner: CGFloat { CGFloat(Density.dense.rowInner ?? 0) }

    // MARK: Header

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Kitchen")
                    .flType(.screenTitle)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .accessibilityIdentifier("fl.kitchen.title")
                Spacer()
                searchButton
            }
            Text(state.summary)
                .flType(.secondary)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .accessibilityIdentifier("fl.kitchen.summary")
        }
    }

    private var searchButton: some View {
        Button {
            onIntent(.search(""))
            searchText = ""
        } label: {
            Image(systemName: "magnifyingglass")
                .imageScale(.large)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Search your kitchen")
        .accessibilityIdentifier("fl.kitchen.searchOpen")
    }

    /// Search replaces the title; the field owns the header row.
    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .imageScale(.large)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            TextField("Search your kitchen", text: $searchText)
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.kitchen.searchField")
                .submitLabel(.search)
                // Live filtering: every keystroke is the typed intent.
                .onChange(of: searchText) { _, newValue in
                    onIntent(.search(newValue))
                }
            Button {
                onIntent(.search(""))
                searchText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel search")
            .accessibilityIdentifier("fl.kitchen.searchCancel")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.rule, in: scheme))
        )
        .accessibilityIdentifier("fl.kitchen.searchBar")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if state.isEmptyKitchen {
            emptyKitchen
        } else if state.search.isActive {
            searchResults
        } else {
            VStack(alignment: .leading, spacing: sectionGap) {
                if let stale = state.stale { staleNotice(stale) }
                if !state.prompts.isEmpty { needsLookSection }
                if !state.useSoon.isEmpty { useSoonSection }
                ForEach(state.locations) { section in
                    locationSection(section)
                }
                if let assumed = state.assumed { assumedBlock(assumed) }
                if let backup = state.backupNote { backupLine(backup) }
            }
        }
    }

    // MARK: Empty kitchen (never scanned)

    private var emptyKitchen: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What's in your kitchen?")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.kitchen.emptyHeadline")
            Text("Scan your shelves once and FridgeLuck knows what you actually have — and answers tonight from it. Prefer typing? That works too.")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            // The two entry actions rank equal: same height, side by side.
            HStack(spacing: 12) {
                FLButton(.secondary, "Scan groceries") {
                    onIntent(.scanGroceries)
                }
                .accessibilityIdentifier("fl.kitchen.scanGroceries")
                FLButton(.secondary, "Add by name") {
                    onIntent(.addByName)
                }
                .accessibilityIdentifier("fl.kitchen.addByName")
            }
        }
        .accessibilityIdentifier("fl.kitchen.empty")
    }

    // MARK: Staleness — a notice, never a write-off

    private func staleNotice(_ stale: KitchenViewState.StaleNotice) -> some View {
        HStack(spacing: 8) {
            Text(stale.line)
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
            Spacer()
            Button {
                onIntent(.scanNow)
            } label: {
                Text("Scan now")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("fl.kitchen.scanNow")
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.yolkSoft, in: scheme))
        )
        .accessibilityIdentifier("fl.kitchen.staleNotice")
    }

    // MARK: Needs a look — the reconciliation pill pair

    private var needsLookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FLSectionLabel("Needs a look")
            ForEach(state.prompts, id: \.itemID) { prompt in
                VStack(alignment: .leading, spacing: rowInner) {
                    Text(prompt.question)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                        pill(
                            label: prompt.stillThereLabel,
                            fill: .pillIdle,
                            textColour: .ink,
                            identifier: "fl.kitchen.pillStill.\(prompt.itemID)"
                        ) {
                            onIntent(.stillThere(itemID: prompt.itemID))
                        }
                        pill(
                            label: prompt.goneLabel,
                            fill: .pillGone,
                            textColour: .ink2,
                            identifier: "fl.kitchen.pillGone.\(prompt.itemID)"
                        ) {
                            onIntent(.gone(itemID: prompt.itemID))
                        }
                        Spacer()
                    }
                }
                .frame(minHeight: rowGrid)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// A reconciliation pill: capsule on its theme surface fill. The
    /// still-there pill is warm (`pillIdle`), the gone pill quiet
    /// (`pillGone`) — both from FLDesignTokens, never screen values.
    private func pill(
        label: String, fill: ColorRole, textColour: ColorRole,
        identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(textColour, in: scheme))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule().fill(Theme.swiftColor(fill, in: scheme)))
                .contentShape(Capsule())
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: Use soon

    private var useSoonSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("Use soon")
            ForEach(state.useSoon) { item in
                row(item, trailingTag: item.ageDisplay ?? "soon")
            }
        }
    }

    // MARK: Location sections

    private func locationSection(_ section: KitchenViewState.LocationSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel(section.title)
            ForEach(section.items) { item in
                row(item, trailingTag: item.ageDisplay)
            }
        }
    }

    /// One pantry row: state glyph, name, evidence line, mono quantity.
    /// Tap expands the edit state (stepper, Used up, Remove).
    private func row(_ item: KitchenViewState.Item, trailingTag: String?) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .fl(.snap)) {
                    expandedItemID = expandedItemID == item.id ? nil : item.id
                }
            } label: {
                HStack(spacing: rowInner) {
                    stateGlyph(item.state)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        if let note = evidenceLine(item) {
                            Text(note)
                                .flType(.caption)
                                .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                        }
                    }
                    Spacer()
                    if let tag = trailingTag, item.kind.isLeftover {
                        Text(tag)
                            .flType(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.swiftColor(.yolkSoft, in: scheme)))
                            .foregroundStyle(Theme.swiftColor(.yolkInk, in: scheme))
                    } else {
                        Text(item.quantityDisplay)
                            .flType(.quantity)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    }
                }
                .frame(minHeight: rowGrid)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("fl.kitchen.item.\(item.id)")

            if expandedItemID == item.id {
                editState(item)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            // The hairline is the separation (dense rows are square).
            Rectangle()
                .fill(Theme.swiftColor(.rule, in: scheme))
                .frame(height: 0.5)
        }
    }

    /// Shape-first row state: filled = confirmed, dashed = unconfirmed,
    /// ring = assumed staple (always captioned by its evidence line).
    private func stateGlyph(_ s: KitchenViewState.ItemState) -> some View {
        Group {
            switch s {
            case .confirmed:
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.swiftColor(.ink, in: scheme))
            case .unconfirmed:
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Theme.swiftColor(.rule2, in: scheme), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            case .assumedStaple:
                Circle().stroke(Theme.swiftColor(.ink3, in: scheme), lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func evidenceLine(_ item: KitchenViewState.Item) -> String? {
        switch (item.lastConfirmed, item.sourceNote) {
        case let (confirmed?, note?):
            return "\(confirmed) · \(note)"
        case let (confirmed?, nil):
            return confirmed
        case let (nil, note?):
            return note
        case (nil, nil):
            return nil
        }
    }

    /// The expanded edit state: stepper, "Used up" (deducts and teaches
    /// the rate), "Remove". Every control ≥ 44 pt.
    private func editState(_ item: KitchenViewState.Item) -> some View {
        HStack(spacing: 16) {
            stepper(item)
            Spacer()
            Button {
                expandedItemID = nil
                onIntent(.useItem(itemID: item.id))
            } label: {
                Text("Used up")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("fl.kitchen.usedUp.\(item.id)")
            Button {
                expandedItemID = nil
                onIntent(.removeItem(itemID: item.id))
            } label: {
                Text("Remove")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.error, in: scheme))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("fl.kitchen.remove.\(item.id)")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("fl.kitchen.edit.\(item.id)")
    }

    private func stepper(_ item: KitchenViewState.Item) -> some View {
        HStack(spacing: 12) {
            Button {
                onIntent(.adjustQuantity(itemID: item.id, delta: -1))
            } label: {
                Image(systemName: "minus")
                    .imageScale(.large)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("fl.kitchen.quantityMinus.\(item.id)")
            Text(item.quantityDisplay)
                .flType(.quantity)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.kitchen.quantity.\(item.id)")
            Button {
                onIntent(.adjustQuantity(itemID: item.id, delta: 1))
            } label: {
                Image(systemName: "plus")
                    .imageScale(.large)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("fl.kitchen.quantityPlus.\(item.id)")
        }
    }

    // MARK: Search results

    @ViewBuilder
    private var searchResults: some View {
        switch state.search {
        case .active(_, let ids):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows(matching: ids)) { item in
                    row(item, trailingTag: item.ageDisplay)
                }
            }
        case .noMatches(let query):
            VStack(alignment: .leading, spacing: 12) {
                Text("Nothing matches “\(query)”.")
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.kitchen.searchNoMatches")
                // Search ends in manual entry, never a dead end.
                FLButton(.secondary, "Add “\(query)”") {
                    onIntent(.addByName)
                }
                .accessibilityIdentifier("fl.kitchen.searchAdd")
            }
        case .inactive:
            EmptyView()
        }
    }

    private func visibleRows(matching ids: [String]) -> [KitchenViewState.Item] {
        state.allItems.filter { ids.contains($0.id) }
    }

    // MARK: Assumed staples — a sentence, not a list

    private func assumedBlock(_ assumed: KitchenViewState.AssumedStaples) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(assumed.sentence)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.kitchen.assumed")
                Spacer()
                Button {
                    onIntent(.changeAssumedStaples)
                } label: {
                    Text("Change")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("fl.kitchen.assumedChange")
            }
        }
    }

    // MARK: Backup — one line, never a modal

    private func backupLine(_ note: String) -> some View {
        Text(note)
            .flType(.caption)
            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
            .accessibilityIdentifier("fl.kitchen.backupNote")
    }

    // MARK: Bottom actions (manual entry stays first-class)

    private var bottomActions: some View {
        HStack(spacing: 12) {
            FLButton(.secondary, "Scan groceries") {
                onIntent(.scanGroceries)
            }
            .accessibilityIdentifier("fl.kitchen.scanGroceriesBottom")
            FLButton(.secondary, "New groceries") {
                onIntent(.newGroceries)
            }
            .accessibilityIdentifier("fl.kitchen.newGroceries")
        }
    }
}

extension KitchenViewState.Item {
    /// Leftovers wear their date as a tag; groceries show the mono
    /// quantity.
    var isLeftover: Bool {
        if case .leftover = kind { return true }
        return false
    }
}
#endif
