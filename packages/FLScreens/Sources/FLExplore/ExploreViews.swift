// FLExplore — the SwiftUI screen.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
// Verification needs a Mac or the staged render workflow. See the
// package README and Part 2's TonightViews header for the same caveat.
//
// Craft rules this file encodes (the Explore/Table mock + the binding
// constraints):
// - Every colour through Theme.swiftColor, every type through .flType,
//   every radius through Radius, photo geometry through PhotoLayoutRule —
//   the screen contains no visual value of its own.
// - Density: the feed is a scanning surface — `Density.dense` (the token
//   doc lists lists/tables as dense).
// - The Table entry is a row INSIDE Explore, beta-flagged; not a tab.
// - Search never dead-ends (zero-hits line), rows never hide (the
//   moreToCook band), social proof follows the ten-cook rule.
// - Text-kind actions wrap to 44 pt minimum; motion is a fade, dropped
//   under Reduce Motion.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

public struct ExploreView: View {

    /// The screen's state. The host owns it; the view only dispatches.
    @Binding var state: ExploreViewState
    /// Every tap becomes a typed intent. The view routes nothing itself.
    let onIntent: (ExploreIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: Binding<ExploreViewState>, onIntent: @escaping (ExploreIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                searchField
                filterChips
                feed
            }
            .animation(reduceMotion ? nil : .fl(.fade), value: state.sections)
        }
        .accessibilityIdentifier("fl.explore.screen")
    }

    // MARK: Search and filters

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
            TextField("Search recipes and cooks", text: searchBinding)
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.explore.search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Radius.buttonOrChip.rawValue), style: .continuous)
                .fill(Theme.swiftColor(.pillIdle, in: scheme))
        )
        .padding(.horizontal, CGFloat(Density.dense.sideMargin))
        .padding(.top, 12)
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { state.query },
            set: { onIntent(.search($0)) }
        )
    }

    @ViewBuilder
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                ForEach(ExploreViewState.Filter.allCases, id: \.self) { filter in
                    FLChip(
                        filter.title,
                        isSelected: state.activeFilters.contains(filter)
                    ) {
                        onIntent(.toggleFilter(filter))
                    }
                    .accessibilityIdentifier("fl.explore.filter.\(filter.rawValue)")
                }
            }
            .padding(.horizontal, CGFloat(Density.dense.sideMargin))
            .padding(.vertical, 8)
        }
    }

    // MARK: Feed

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat(Density.dense.sectionGap ?? 24)) {
                if state.showsTableEntry { tableEntry }
                if state.rowsLoading { FLEmptyLoadingLine().accessibilityIdentifier("fl.explore.loading") }
                ForEach(state.sections) { section in
                    sectionView(section)
                }
                if state.showsZeroHits {
                    zeroHits
                } else if state.showsEmptyState {
                    emptyState
                }
            }
            .padding(.horizontal, CGFloat(Density.dense.sideMargin))
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionView(_ section: ExploreViewState.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel(section.band.title)
                .accessibilityIdentifier("fl.explore.section.\(section.band.rawValue)")
            ForEach(section.rows) { row in
                feedRow(row)
            }
        }
    }

    private func feedRow(_ row: ExploreViewState.Row) -> some View {
        FLHairlineRow(haptic: .lightConfirm) {
            onIntent(.openRecipe(recipeID: row.id))
        } content: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .flType(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .lineLimit(2)
                    Text(row.captionDisplay)
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(row.fit.lineText)
                            .flTracking(.fitCount)
                            .flType(.fitCount)
                            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        Text(row.minutesDisplay)
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    }
                    .accessibilityElement(children: .combine)
                    if row.isPendingReview {
                        Button("Withdraw") { onIntent(.withdraw(recipeID: row.id)) }
                            .flType(.secondary)
                            .foregroundStyle(Theme.swiftColor(.error, in: scheme))
                            .frame(minHeight: 44, alignment: .leading)
                            .accessibilityIdentifier("fl.explore.withdraw")
                    }
                }
                Spacer(minLength: 12)
                if row.photoCaption != nil {
                    thumbnail
                }
            }
        }
        .accessibilityIdentifier("fl.explore.row.\(row.id)")
        .accessibilityLabel("\(row.title), \(row.captionDisplay), \(row.fit.lineText), \(row.minutesDisplay)")
    }

    /// The row thumbnail: 3:2 by the shared rule. The host supplies the
    /// imagery; the package ships the area.
    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: CGFloat(Radius.row.rawValue), style: .continuous)
            .fill(Theme.swiftColor(.rule, in: scheme))
            .aspectRatio(CGFloat(PhotoLayoutRule.aspectRatio), contentMode: .fit)
            .frame(width: 64)
            .accessibilityHidden(true)
    }

    // MARK: Beta entry — Table inside Explore

    private var tableEntry: some View {
        FLHairlineRow(haptic: .lightConfirm) {
            onIntent(.openTable)
        } content: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Community tables")
                        .flType(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    Text("Beta · what your table actually cooked, in time order")
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
            }
        }
        .accessibilityIdentifier("fl.explore.tableEntry")
    }

    // MARK: Empty and zero-hit states

    private var zeroHits: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.zeroHitsMessage)
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            Button("Clear") { onIntent(.clearFilters) }
                .flType(.secondary)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("fl.explore.clearFilters")
        }
        .accessibilityIdentifier("fl.explore.zeroHits")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing published yet. Be the first — publish from your cookbook, or browse the catalog.")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
            HStack(spacing: 12) {
                Button("Open cookbook") { onIntent(.openCookbook) }
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    .frame(minHeight: 44, alignment: .leading)
                Button("Search the catalog") { onIntent(.openCatalogSearch) }
                    .flType(.secondary)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
        .accessibilityIdentifier("fl.explore.empty")
    }
}
#endif
