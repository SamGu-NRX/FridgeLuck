// FLScreenSupport — the shell view.
//
// The native iOS tab shell, driven entirely by FLShellConfiguration (the
// tab list is configuration — Sam's round decision on PR #95):
//
// - `standard`: four tabs (Tonight, Kitchen, Explore, Cookbook) with Scan
//   as the trailing SEARCH-ROLE tab — `Tab(_:systemImage:role:.search)`.
//   The custom label ("Scan") and icon ("viewfinder") on a search-role tab
//   are verified supported per the round decision. CAVEAT (documented,
//   never asserted as rendered): a search-role tab is presented by the
//   system — iOS may restyle it and typically opens it into a search
//   presentation. The host should verify the presentation matches Scan's
//   flow on a device; the documented fallback is Scan as a prominent
//   action on Tonight and Kitchen (both screens already ship it).
// - `shellS`: two tabs (Kitchen, Progress) with Scan as the NATIVE bottom
//   tab-bar accessory (`.tabViewBottomAccessory`) — never a hand-rolled
//   floating orb.
//
// UNVERIFIED-NATIVE: `Tab`, `TabRole`, and `tabViewBottomAccessory` are
// iOS 18+ SwiftUI APIs. This package compiles on Linux only as an empty
// module and has never been compiled by a Swift compiler that carries
// SwiftUI; native compilation and rendering need a Mac or the staged CI
// workflow (ci/pending-workflows/screens-renders.yml — HELD, not
// installed). See the package README.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
import FLDesignTokens

#if os(iOS)
/// The shell for the configurations that use the native tab list.
/// Destinations are supplied per tab id by the host; the shell invents
/// none.
public struct FLShellView<Destination: View>: View {

    private let configuration: FLShellConfiguration
    private let destination: (FLShellTab) -> Destination
    /// Shell S: the scan control the system presents in the bottom
    /// accessory slot.
    private let scanAccessory: (() -> AnyView)?

    public init(
        configuration: FLShellConfiguration,
        @ViewBuilder destination: @escaping (FLShellTab) -> Destination,
        scanAccessory: (() -> AnyView)? = nil
    ) {
        self.configuration = configuration
        self.destination = destination
        self.scanAccessory = scanAccessory
    }

    public var body: some View {
        let regular = configuration.tabs.filter { $0.role == .regular }
        let search = configuration.tabs.filter { $0.role == .search }

        TabView {
            ForEach(regular) { tab in
                Tab(tab.title, systemImage: tab.systemImage) {
                    destination(tab)
                        .accessibilityIdentifier("fl.shell.tab.\(tab.id)")
                        // Optional count (Shell S's needs-a-look caption);
                        // nil renders no badge.
                        .badge(tab.badgeDisplay)
                }
            }
            ForEach(search) { tab in
                // Search-role trailing tab. Custom label and icon are
                // verified supported (round decision); the presentation is
                // the system's (see the caveat above).
                Tab(tab.title, systemImage: tab.systemImage, role: .search) {
                    destination(tab)
                        .accessibilityIdentifier("fl.shell.tab.\(tab.id)")
                        .badge(tab.badgeDisplay)
                }
            }
        }
        .modify { view in
            if configuration.scanPlacement == .bottomAccessory, let scanAccessory {
                AnyView(view.tabViewBottomAccessory(content: scanAccessory))
            } else {
                AnyView(view)
            }
        }
    }
}

extension View {
    /// Tiny helper so the accessory branch above can stay an expression.
    fileprivate func modify(_ transform: (Self) -> some View) -> some View {
        transform(self)
    }
}
#else
// macOS: the app ships on iPhone; a plain tab list keeps the package
// compiling for AppKit hosts without pretending iOS 26 chrome exists.
public struct FLShellView<Destination: View>: View {
    private let configuration: FLShellConfiguration
    private let destination: (FLShellTab) -> Destination

    public init(
        configuration: FLShellConfiguration,
        @ViewBuilder destination: @escaping (FLShellTab) -> Destination,
        scanAccessory: (() -> AnyView)? = nil
    ) {
        self.configuration = configuration
        self.destination = destination
    }

    public var body: some View {
        TabView {
            ForEach(configuration.tabs.filter { $0.role == .regular }) { tab in
                destination(tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .accessibilityIdentifier("fl.shell.tab.\(tab.id)")
            }
        }
    }
}
#endif
#endif
