// FLKitchenTests — Shell S reuse pins.
//
// Shell S presents Kitchen with the ALTERNATE shell chrome: no Explore
// tab (Explore is reached from inside Kitchen), Scan in the Part 2
// shell's bottom-accessory slot. The binding constraint: the SAME
// FLKitchen module renders under both configurations — the composition
// file (ShellSKitchenViews.swift) embeds `KitchenView(state:)` and adds
// only the alternate chrome AROUND it. It must never fork the Kitchen
// view, re-declare its header/title, or build tab chrome (the Part 2
// shell is authoritative; Shell S is a configuration of it).
//
// The SwiftUI composition is Apple-gated (UNVERIFIED-NATIVE), so the
// contract is verified at the source level here, Linux-run.

import XCTest

final class ShellSReuseTests: XCTestCase {

    // MARK: Locating the sources (from #filePath — no cwd assumptions)

    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private func source(_ relative: String) throws -> String {
        let url = packageRoot.appendingPathComponent("Sources").appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: The reuse contract

    func testShellSCompositionEmbedsTheUnmodifiedKitchenView() throws {
        let text = try source("FLKitchen/ShellSKitchenViews.swift")
        XCTAssertTrue(
            text.contains("KitchenView(state:"),
            "the Shell S composition must embed the unmodified KitchenView")
        XCTAssertFalse(
            text.contains("struct KitchenView"),
            "the composition must not re-declare KitchenView — no fork")
        XCTAssertFalse(
            text.contains("fl.kitchen.title"),
            "the composition must not render a second Kitchen title — KitchenView owns its header")
    }

    func testShellSCompositionAddsOnlyTheAlternateChrome() throws {
        let text = try source("FLKitchen/ShellSKitchenViews.swift")
        XCTAssertTrue(
            text.contains("fl.kitchen.shellSExplore"),
            "Shell S reaches Explore from Kitchen (no Explore tab there) — the row must be identified")
        for banned in ["TabView", "TabBar(", "tabItem"] {
            XCTAssertFalse(
                text.contains(banned),
                "the composition must not build its own \(banned) — the Part 2 shell owns the tabs and the Scan accessory")
        }
    }

    func testShellSCompositionIsAppleGated() throws {
        let text = try source("FLKitchen/ShellSKitchenViews.swift")
        XCTAssertTrue(text.contains("#if canImport(UIKit)"), "the composition must be Apple-gated")
        XCTAssertTrue(text.contains("UNVERIFIED-NATIVE"), "the composition must carry the unverified-native note")
    }
}
