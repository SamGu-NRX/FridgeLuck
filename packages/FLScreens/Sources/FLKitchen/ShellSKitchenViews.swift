// FLKitchen — Shell S's Kitchen composition.
//
// UNVERIFIED-NATIVE: compiles only where SwiftUI exists. Linux builds this
// target's state files as Foundation; this file is Apple-gated and has
// never been compiled or rendered by a SwiftUI-capable toolchain.
// Verification needs a Mac or the staged render workflow. See the
// package README and Part 2's TonightViews header for the same caveat.
//
// THE REUSE CONTRACT (Part 6 scope note): Kitchen under Shell S is the
// SAME Kitchen, in the alternate shell chrome — never a fork. This file
// is a thin composition: the unmodified `KitchenView` plus the one
// affordance Shell S's arrangement needs. The Part 2 shell is
// authoritative: `FLShellConfiguration.shellS` (two tabs — Kitchen,
// Progress — with Scan as the native bottom-tab accessory) maps this
// tab; the mock's custom floating orb is that accessory's content,
// host-wired, not rebuilt here. The needs-a-look badge lives in the
// tab's caption (`FLShellTab.badgeDisplay`, wired in the shell views) —
// never a red dot on the accessory, per the mock's note.
//
// Why the Explore row exists: under Shell S, Explore is not a tab (two
// tabs only), so the mock gives Kitchen's header a quiet "Explore →"
// link. The unforked `KitchenView` already renders its own title row
// with the search affordance, so the link rides as its own quiet row
// above the embedded screen rather than inside Kitchen's title. nil
// handler = no row: the default shell (where Explore IS a tab) never
// shows it, and nothing else in Kitchen changes.
//
// Lint-pinned by Part6RawSourceLintTests: this file must reference
// `KitchenView(state:` (the reuse) and must not re-declare Kitchen's
// title or rows.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens
import FLDesignSystem
import FLScreenSupport

public struct ShellSKitchenView: View {

    /// The SAME kitchen state the default shell's Kitchen tab binds.
    /// No second state type exists for Shell S — that would be a fork.
    @Binding var state: KitchenViewState
    /// The SAME kitchen intents, passed through untouched.
    let onKitchenIntent: (KitchenIntent) -> Void
    /// Opens the Explore tab. Shell S only (no Explore tab there); nil
    /// hides the row — the default shell never passes a handler.
    var exploreAccess: (() -> Void)?

    @Environment(\.flScheme) private var scheme

    public init(
        state: Binding<KitchenViewState>,
        onKitchenIntent: @escaping (KitchenIntent) -> Void,
        exploreAccess: (() -> Void)? = nil
    ) {
        _state = state
        self.onKitchenIntent = onKitchenIntent
        self.exploreAccess = exploreAccess
    }

    public var body: some View {
        ZStack {
            Theme.swiftColor(.bg, in: scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                if let exploreAccess {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            exploreAccess()
                        } label: {
                            HStack(spacing: 4) {
                                Text("Explore")
                                Image(systemName: "arrow.right")
                            }
                            .flType(.caption)
                            .foregroundStyle(Theme.swiftColor(.ink2, in: scheme))
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Explore recipes")
                        .accessibilityIdentifier("fl.kitchen.shellSExplore")
                    }
                    .padding(.horizontal, CGFloat(Density.dense.sideMargin))
                    .padding(.top, 4)
                }

                // The unmodified Kitchen screen — the reuse is the point.
                KitchenView(state: $state, onIntent: onKitchenIntent)
            }
        }
        .accessibilityIdentifier("fl.kitchen.shellSScreen")
    }
}
#endif
