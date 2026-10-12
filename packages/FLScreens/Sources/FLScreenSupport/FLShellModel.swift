// FLScreenSupport — the shell configuration model.
//
// From Sam's round decision on PR #95: the shell is a native iOS 26
// TabView whose TAB LIST IS CONFIGURATION. Nothing in a screen may assume
// which tabs exist or where Scan sits; hosts and render harnesses choose.
//
// Two configurations exist today:
//
// - `standard` — the default four tabs (Tonight, Kitchen, Explore,
//   Cookbook) with Scan as a trailing search-role tab
//   (`Tab(_:systemImage:role:.search)`; custom label and icon are verified
//   supported). Table is NOT a tab: it lives inside Explore behind its beta
//   flag.
// - `shellS` — Sam's Shell S: two tabs (Kitchen, Progress) with Scan as a
//   bottom accessory, built with the native accessory APIs — never a
//   hand-rolled floating orb.
//
// Foundation-only: the model is data, testable on Linux. The SwiftUI view
// that renders it (`FLShellView`) is Apple-gated in this same target.

/// One tab in the shell's list. `id` is stable for host wiring and
/// accessibility identifiers (`fl.shell.tab.<id>`); title and symbol are
/// the tab's visible label.
public struct FLShellTab: Equatable, Identifiable, Sendable {

    /// Search-role tabs are presented by the system (see `FLShellView`'s
    /// caveat note); regular tabs are ordinary destinations.
    public enum Role: Equatable, Sendable {
        case regular
        case search
    }

    public var id: String
    public var title: String
    public var systemImage: String
    public var role: Role
    /// A small count shown on the tab itself (Shell S's mock carries the
    /// Kitchen needs-a-look count in the tab caption — mono, never a red
    /// dot on the scan accessory). Display-only: the host computes it from
    /// the kitchen's state and this type never reads a screen. nil = no
    /// badge; the scan accessory slot has no badge field by construction.
    public var badgeDisplay: String?

    public init(
        id: String, title: String, systemImage: String, role: Role = .regular,
        badgeDisplay: String? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.badgeDisplay = badgeDisplay
    }

    /// The Scan tab, as a search-role entry with a custom label and icon
    /// (verified supported by `Tab(_:systemImage:role:.search)`).
    public static var scanSearchTab: FLShellTab {
        FLShellTab(id: "scan", title: "Scan", systemImage: "viewfinder", role: .search)
    }
}

/// Where the scan action lives in a shell configuration.
public enum FLScanPlacement: Equatable, Sendable {
    /// The default shell: Scan as the trailing search-role tab.
    case searchRoleTab
    /// Shell S: Scan as the native bottom tab-bar accessory.
    case bottomAccessory
}

/// The whole shell as data. A screen never reads this; hosts compose it and
/// hand it to `FLShellView`.
public struct FLShellConfiguration: Equatable, Sendable {

    public var tabs: [FLShellTab]
    public var scanPlacement: FLScanPlacement

    public init(tabs: [FLShellTab], scanPlacement: FLScanPlacement) {
        self.tabs = tabs
        self.scanPlacement = scanPlacement
    }

    /// The default configuration: four tabs, Scan as the trailing
    /// search-role tab. No Table tab — Table lives inside Explore behind
    /// its beta flag (Sam's round decision).
    public static var standard: FLShellConfiguration {
        FLShellConfiguration(
            tabs: [
                FLShellTab(id: "tonight", title: "Tonight", systemImage: "moon.stars"),
                FLShellTab(id: "kitchen", title: "Kitchen", systemImage: "refrigerator"),
                FLShellTab(id: "explore", title: "Explore", systemImage: "sparkles"),
                FLShellTab(id: "cookbook", title: "Cookbook", systemImage: "book"),
                FLShellTab.scanSearchTab,
            ],
            scanPlacement: .searchRoleTab
        )
    }

    /// Sam's Shell S: Kitchen and Progress as the two main tabs (Profile
    /// lives inside Progress), Scan as the native bottom accessory.
    public static var shellS: FLShellConfiguration {
        FLShellConfiguration(
            tabs: [
                FLShellTab(id: "kitchen", title: "Kitchen", systemImage: "refrigerator"),
                FLShellTab(id: "progress", title: "Progress", systemImage: "chart.line.uptrend.xyaxis"),
            ],
            scanPlacement: .bottomAccessory
        )
    }
}
