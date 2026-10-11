// FLScreens lint tests — Part 4 additions, in the Part 2/3 lint suite's
// conventions.
//
// Part 4 adds FLScan and FLTasteProfile. The raw-source lint keeps
// scanning every Sources/ file for hex colours and font construction
// (LintTests.swift); these tests add what Part 4's screens owe:
//
// - Scan / Taste view files exist, are Apple-gated, carry the
//   unverified-native note, and pin the theme through
//   FLRenderPaletteMapping's scheme environment — a Direction P render
//   resolves through the same code path.
// - Photo geometry in Scan goes through FLDesignTokens' PhotoLayoutRule
//   (3:2, never above the height cap) — the review screen's photo
//   placeholder is the only Part 4 photo surface. The taste profile
//   shows no photos, so it must NOT mention PhotoLayoutRule.
// - State files stay Foundation-only: no SwiftUI, UIKit or Combine
//   imports — Linux must be able to test all of the logic.
// - No confidence percentage anywhere in Scan: recognition results are
//   "sure" or a question — never a number the user is asked to weigh.
// - Every accessibility identifier the views set uses the fl.scan. or
//   fl.taste. prefix from docs/screens/a11y-identifiers.md.

import XCTest

final class Part4RawSourceLintTests: XCTestCase {

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

    // MARK: Existence and gating

    private let part4ViewFiles = [
        "FLScan/ScanViews.swift",
        "FLTasteProfile/TasteViews.swift",
    ]

    func testPart4ViewFilesExistAndAreAppleGated() throws {
        for file in part4ViewFiles {
            let text = try source(file)
            XCTAssertTrue(text.contains("#if canImport(UIKit)"), "\(file) must be Apple-gated")
            XCTAssertTrue(text.contains("UNVERIFIED-NATIVE"), "\(file) must carry the unverified-native note")
        }
    }

    func testPart4ViewFilesResolveTheThemeThroughTheMappingScheme() throws {
        for file in part4ViewFiles {
            let text = try source(file)
            XCTAssertTrue(text.contains("flScheme"), "\(file) must read the theme-scheme environment")
            XCTAssertTrue(text.contains("Theme.swiftColor"), "\(file) must consume Theme colors")
            XCTAssertTrue(text.contains(".flType("), "\(file) must set type through .flType")
            XCTAssertFalse(text.contains("DirectionH"), "\(file) must not name a direction")
            XCTAssertFalse(text.contains("DirectionP"), "\(file) must not name a direction")
            XCTAssertFalse(text.contains("systemGray"), "\(file) must not hard-code semantic greys")
        }
    }

    // MARK: Photo geometry — Scan only; the taste profile shows no photos

    func testScanPhotoGeometryGoesThroughTheSharedPhotoRule() throws {
        let scan = try source("FLScan/ScanViews.swift")
        XCTAssertTrue(
            scan.contains("PhotoLayoutRule"),
            "ScanViews draws the review photo and must use FLDesignTokens.PhotoLayoutRule")
        XCTAssertFalse(
            scan.lowercased().contains("3.0 / 2"),
            "ScanViews must not hand-roll the 3:2 aspect ratio")

        let taste = try source("FLTasteProfile/TasteViews.swift")
        XCTAssertFalse(
            taste.contains("PhotoLayoutRule"),
            "the taste profile shows no photos — a rule there means someone drew one")
    }

    // MARK: State files stay Foundation-only

    func testPart4StateFilesImportOnlyFoundationLevelModules() throws {
        let stateFiles = [
            "FLScan/ScanViewState.swift",
            "FLScan/ScanIntent.swift",
            "FLTasteProfile/TasteViewState.swift",
            "FLTasteProfile/TasteIntent.swift",
        ]
        for file in stateFiles {
            let text = try source(file)
            for banned in ["import SwiftUI", "import UIKit", "import Combine"] {
                XCTAssertFalse(
                    text.contains(banned),
                    "\(file) must stay Foundation-only — Linux tests all of the logic")
            }
        }
    }

    // MARK: No confidence percentage in Scan

    func testScanNeverShowsAConfidenceNumber() throws {
        for file in ["FLScan/ScanViewState.swift", "FLScan/ScanIntent.swift", "FLScan/ScanViews.swift"] {
            let text = try source(file)
            for word in ["confidence", "certainty", "percent"] {
                XCTAssertFalse(
                    text.lowercased().contains(word),
                    "\(file) must not carry a \(word) — items are sure or a question, never a number to weigh")
            }
        }
    }

    // MARK: Accessibility identifiers use the Part 4 prefixes

    func testScanIdentifiersUseTheScanPrefix() throws {
        let text = try source("FLScan/ScanViews.swift")
        let identifiers = identifiersFound(in: text)
        XCTAssertFalse(identifiers.isEmpty, "ScanViews must set accessibility identifiers")
        for identifier in identifiers {
            XCTAssertTrue(
                identifier.hasPrefix("fl.scan."),
                "ScanViews identifier \(identifier) must use the fl.scan. prefix")
        }
    }

    func testTasteIdentifiersUseTheTastePrefix() throws {
        let text = try source("FLTasteProfile/TasteViews.swift")
        let identifiers = identifiersFound(in: text)
        XCTAssertFalse(identifiers.isEmpty, "TasteViews must set accessibility identifiers")
        for identifier in identifiers {
            XCTAssertTrue(
                identifier.hasPrefix("fl.taste."),
                "TasteViews identifier \(identifier) must use the fl.taste. prefix")
        }
    }

    /// Pulls every string literal that looks like a namespaced identifier
    /// (`something.something` with a dot in the first segment) from the raw
    /// source — including gated-out code.
    private func identifiersFound(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\"((?:fl|FL)\\.[a-z]+\\.[A-Za-z0-9.]+)\"")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range)
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    // MARK: The dock stays shell-owned

    func testScanModuleBuildsNoDockOfItsOwn() throws {
        // The shell owns the tab bar and the search-role slot (Part 2).
        // Scan is a destination inside it — never its own tab hierarchy
        // or dock. (The capture-stage shutter ring is camera content, not
        // dock chrome, so shapes are not banned here.)
        let text = try source("FLScan/ScanViews.swift")
        for banned in ["TabView", "TabBar", "tabItem"] {
            XCTAssertFalse(
                text.contains(banned),
                "ScanViews must not build its own \(banned) — the Part 2 shell owns the dock")
        }
        XCTAssertTrue(
            text.contains("FLScreenSupport") || text.contains("FLDesignSystem"),
            "ScanViews must consume the shared support/design-system surface")
    }
}
