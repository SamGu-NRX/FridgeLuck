// FLProgress — the SwiftUI screens.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
// Verification needs a Mac or the staged render workflow. See the
// package README and Part 2's TonightViews header for the same caveat.
//
// Craft rules this file encodes (the Shell S Progress + Profile mocks +
// the binding constraints):
// - Every colour through Theme.swiftColor, every type through .flType,
//   every radius through Radius — the screens contain no visual value of
//   their own. The mock's 44 pt mono counter has no token role; the
//   counter value uses the `.dishTitle` role (the system's large data
//   display) and the divergence is recorded in part6-notes.
// - Density: rows lists — `Density.dense`. This struct is named
//   FLProgressView, not ProgressView: SwiftUI owns that name.
// - Shell S is a CONFIGURATION of the Part 2 shell; these views build no
//   tab bar and no accessory — the shell supplies the chrome, these
//   views only ever fill a tab's destination or a pushed screen.
// - First run: counters render as 0 in the quiet colour ("not dashes"),
//   the empty line stands in for the list.
// - Counters settle in place; no count-up spin — the numbers are facts.
//   Value changes fade through the system token, dropped under Reduce
//   Motion.
// - Kitchen is never rebuilt here: under Shell S the shell maps its
//   kitchen tab to the SAME FLKitchen views (pinned by
//   ShellSReuseTests in FLKitchenTests).
// - Profile is one screen of rows, no cards: the household, the
//   evidence sizes, the data controls. Forget is the last row, quiet by
//   position, confirmed before it acts (inline confirmation, the taste
//   module's pattern), reversible within the state's undo window.
// - Nothing here is ever surfaced to community (SPEC §3.4); the share
//   side of that line lives in FLQuests.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

// MARK: - Progress (the Shell S tab)

public struct FLProgressView: View {

    /// The screen's state. The host owns it; the view only dispatches.
    @Binding var state: ProgressViewState
    /// Every tap becomes a typed intent. The view routes nothing itself.
    let onIntent: (ProgressIntent) -> Void

    @Environment(\.flScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: Binding<ProgressViewState>, onIntent: @escaping (ProgressIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
                    header
                    counters
                    if !state.isFirstRun { weekSection }
                    youSection
                }
                .padding(.horizontal, CGFloat(Density.dense.sideMargin))
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("fl.progress.screen")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Progress")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.progress.title")
            if let weekLabel = state.weekLabel {
                Text(weekLabel)
                    .flType(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.progress.weekLabel")
            }
        }
    }

    // MARK: Counters

    @ViewBuilder
    private var counters: some View {
        // Three counters settle in place; on first run they render as 0
        // in the quiet colour — numbers are facts, not excitement.
        HStack(alignment: .top, spacing: 20) {
            counter(value: "\(state.counters.cookedThisWeek)", label: "cooked", id: "fl.progress.cooked")
            counter(value: "\(state.counters.weekStreak)", label: "week streak", id: "fl.progress.streak")
            counter(value: state.savedFoodDisplay, label: "saved", id: "fl.progress.saved")
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("fl.progress.counters")
        .animation(reduceMotion ? nil : .fl(.fade), value: state.counters)
    }

    private func counter(value: String, label: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .flType(.dishTitle)
                .foregroundStyle(Theme.swiftColor(state.isFirstRun ? .ink3 : .ink, in: scheme))
            Text(label)
                .flType(.caption)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: This week

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("This week")
                .accessibilityIdentifier("fl.progress.weekSection")
            // The host's order is the host's statement; rows never
            // re-sort.
            ForEach(state.weekCooks) { cook in
                FLHairlineRow(haptic: .lightConfirm) {
                    onIntent(.openCook(id: cook.id))
                } content: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cook.dayDisplay)
                                .flType(.body)
                                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            Text(cook.dishDisplay)
                                .flType(.caption)
                                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        }
                        Spacer(minLength: 8)
                        Text(cook.ratingDisplay)
                            .flType(.quantity)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        Text(cook.timeDisplay)
                            .flType(.evidence)
                            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    }
                }
                .accessibilityIdentifier("fl.progress.weekRow.\(cook.id)")
            }

            if let asOf = state.asOf {
                Text(asOf)
                    .flType(.evidence)
                    .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    .padding(.top, 8)
                    .accessibilityIdentifier("fl.progress.asOf")
            }
        }
    }

    // MARK: You (entries, not chrome)

    private var youSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("You")
            // The quests CANDIDATE's entry: absent entirely while the
            // flag is off — its absence is the off state.
            if state.showsQuestsEntry {
                FLHairlineRow {
                    onIntent(.openQuests)
                } content: {
                    entryRow(title: "Quests", caption: nil)
                }
                .accessibilityIdentifier("fl.progress.questsEntry")
            }

            FLHairlineRow {
                onIntent(.openProfile)
            } content: {
                entryRow(title: "Profile & data", caption: "Taste profile, Forget, sign out")
            }
            .accessibilityIdentifier("fl.progress.profileEntry")
        }
    }

    private func entryRow(title: String, caption: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .flType(.body)
                    .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                if let caption {
                    Text(caption)
                        .flType(.caption)
                        .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .flType(.body)
                .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
        }
    }
}

// MARK: - Profile (pushed inside Progress)

public struct ProfileView: View {

    /// The screen's state. The host owns it; the view only dispatches.
    @Binding var state: ProfileViewState
    /// Every tap becomes a typed intent. The view routes nothing itself.
    let onIntent: (ProfileIntent) -> Void

    @Environment(\.flScheme) private var scheme

    public init(state: Binding<ProfileViewState>, onIntent: @escaping (ProfileIntent) -> Void) {
        _state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(Density.dense.blockGap)) {
                    header
                    if state.householdLine != nil { householdSection }
                    if state.showsEvidenceRows { evidenceSection }
                    dataSection
                    privacyLine
                }
                .padding(.horizontal, CGFloat(Density.dense.sideMargin))
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("fl.profile.screen")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You")
                .flType(.screenTitle)
                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                .accessibilityIdentifier("fl.profile.title")
            Text("this phone")
                .flType(.evidence)
                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                .accessibilityIdentifier("fl.profile.phoneCaption")
        }
    }

    // MARK: Household

    private var householdSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("Household")
                .accessibilityIdentifier("fl.profile.householdSection")
            FLHairlineRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Household")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    if let householdLine = state.householdLine {
                        Text(householdLine)
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    }
                }
            }
            .accessibilityIdentifier("fl.profile.household")
        }
    }

    // MARK: Evidence (sizes only — the data itself never enters this state)

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("Evidence")
                .accessibilityIdentifier("fl.profile.evidenceSection")

            if let tasteSummary = state.tasteSummary {
                FLHairlineRow(haptic: .lightConfirm) {
                    onIntent(.openTasteProfile)
                } content: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Taste profile")
                                .flType(.body)
                                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            Text(tasteSummary)
                                .flType(.caption)
                                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    }
                }
                .accessibilityIdentifier("fl.profile.tasteEntry")
            }

            if let cookbookSummary = state.cookbookSummary {
                FLHairlineRow(haptic: .lightConfirm) {
                    onIntent(.openCookbookRecords)
                } content: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cookbook records")
                                .flType(.body)
                                .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                            Text(cookbookSummary)
                                .flType(.caption)
                                .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                    }
                }
                .accessibilityIdentifier("fl.profile.cookbookEntry")
            }
        }
    }

    // MARK: Data (controls are first-class rows, never buried settings)

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FLSectionLabel("Data")
                .accessibilityIdentifier("fl.profile.dataSection")

            FLHairlineRow(haptic: .lightConfirm) {
                onIntent(.requestExport)
            } content: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export everything")
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        Text("On-device file, share when you want")
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "square.and.arrow.up")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                }
            }
            .accessibilityIdentifier("fl.profile.exportRow")

            forgetSection

            FLHairlineRow(haptic: .lightConfirm) {
                onIntent(.requestSignOut)
            } content: {
                HStack(spacing: 12) {
                    Text("Sign out")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                }
            }
            .accessibilityIdentifier("fl.profile.signOutRow")
        }
    }

    // MARK: The Forget flow (the last rows, quiet by position)

    @ViewBuilder
    private var forgetSection: some View {
        if state.isConfirmingForget {
            // The confirmation, with the size baked into its copy.
            VStack(alignment: .leading, spacing: CGFloat(Density.dense.chipGap ?? 8)) {
                if let confirmLine = state.forgetConfirmLine {
                    Text(confirmLine)
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        .accessibilityIdentifier("fl.profile.forgetConfirmTitle")
                }
                FLButton(.primary, "Forget it", haptic: .mediumCommit) {
                    onIntent(.confirmForget)
                }
                .accessibilityIdentifier("fl.profile.forgetConfirmButton")
                FLButton(.text, "Keep it") {
                    onIntent(.cancelForget)
                }
                .accessibilityIdentifier("fl.profile.forgetCancelButton")
            }
            .padding(.vertical, 12)
            .accessibilityIdentifier("fl.profile.forgetConfirm")
        } else {
            FLHairlineRow(haptic: .mediumCommit) {
                onIntent(.requestForget)
            } content: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Forget taste evidence")
                            .flType(.body)
                            .foregroundStyle(Theme.swiftColor(.ink, in: scheme))
                        Text("Recipes stay; the profile empties")
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .flType(.body)
                        .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
                }
            }
            .accessibilityIdentifier("fl.profile.forgetRow")
        }

        if let receiptLine = state.forgetReceiptLine {
            // The receipt + the undo row (the undo lives while the
            // window runs; the state refuses it once it closes).
            VStack(alignment: .leading, spacing: 8) {
                Text(receiptLine)
                    .flType(.caption)
                    .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                    .accessibilityIdentifier("fl.profile.forgetReceipt")
                if state.isUndoAvailable {
                    FLButton(.text, "Undo") {
                        onIntent(.undoForget)
                    }
                    .accessibilityIdentifier("fl.profile.forgetUndo")
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var privacyLine: some View {
        // The learning contract, stated in place (SPEC §3.3).
        Text("Ranking runs on-device; nothing is shared without a preview you approve.")
            .flType(.caption)
            .foregroundStyle(Theme.swiftColor(.ink3, in: scheme))
            .accessibilityIdentifier("fl.profile.onDeviceLine")
    }
}
#endif
