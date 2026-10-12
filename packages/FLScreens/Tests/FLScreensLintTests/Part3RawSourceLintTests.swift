// FLScreens lint tests — Part 3 additions, in the Part 2 lint suite's
// conventions.
//
// The Part 2 lint already scans every Sources/ file for hex colours and
// font construction (raw source, so gated-out SwiftUI is covered). These
// tests add what Part 3's screens specifically owe:
//
// - Explore / Table / Recipe view files exist, are Apple-gated, and pin
//   the theme through FLRenderPaletteMapping's scheme environment — so a
//   Direction P render resolves through the same code path.
// - Photo geometry in the new screens goes through FLDesignTokens'
//   PhotoLayoutRule (3:2, never above the height cap).
// - The state files stay Foundation-only: no SwiftUI import, no UIKit
//   import — Linux must be able to test all of the logic.
// - TableViewState.SharePreview's declaration mentions only the five
//   shareable fields — the "share previews exactly what leaves the
//   phone" contract holds at the type level.

import XCTest

final class Part3RawSourceLintTests: XCTestCase {

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

    private let viewFiles = [
        "FLExplore/ExploreViews.swift",
        "FLExplore/TableViews.swift",
        "FLRecipe/RecipeViews.swift",
    ]

    func testPart3ViewFilesExistAndAreAppleGated() throws {
        for file in viewFiles {
            let text = try source(file)
            XCTAssertTrue(text.contains("#if canImport(UIKit)"), "\(file) must be Apple-gated")
            XCTAssertTrue(text.contains("UNVERIFIED-NATIVE"), "\(file) must carry the unverified-native note")
        }
    }

    func testViewFilesResolveTheThemeThroughTheMappingScheme() throws {
        // Every view file must read the scheme environment (resolved by
        // FLRenderPaletteMapping) and consume Theme colors through it —
        // never a direction-specific palette type.
        for file in viewFiles {
            let text = try source(file)
            XCTAssertTrue(text.contains("flScheme"), "\(file) must read the theme-scheme environment")
            XCTAssertTrue(text.contains("Theme.swiftColor"), "\(file) must consume Theme colors")
            XCTAssertTrue(text.contains(".flType("), "\(file) must set type through .flType")
            XCTAssertFalse(text.contains("DirectionH"), "\(file) must not name a direction")
            XCTAssertFalse(text.contains("DirectionP"), "\(file) must not name a direction")
        }
    }

    // MARK: Photo geometry

    func testPhotoGeometryGoesThroughTheSharedPhotoRule() throws {
        // Files that draw photos (they mention PhotoLayoutRule for the
        // 3:2 + cap computation) — and none of them may compute aspect
        // ratios by hand.
        for file in viewFiles {
            let text = try source(file)
            XCTAssertTrue(
                text.contains("PhotoLayoutRule"),
                "\(file) draws photos and must use FLDesignTokens.PhotoLayoutRule")
            XCTAssertFalse(
                text.lowercased().contains("3.0 / 2"),
                "\(file) must not hand-roll the 3:2 aspect ratio")
        }
    }

    // MARK: State files stay Foundation-only

    func testStateFilesImportOnlyFoundationLevelModules() throws {
        let stateFiles = [
            "FLExplore/ExploreViewState.swift",
            "FLExplore/ExploreIntent.swift",
            "FLExplore/TableViewState.swift",
            "FLRecipe/RecipeViewState.swift",
        ]
        for file in stateFiles {
            let text = try source(file)
            XCTAssertFalse(
                text.contains("import SwiftUI"),
                "\(file) must stay Foundation-only — Linux tests all of the logic")
            XCTAssertFalse(
                text.contains("import UIKit"),
                "\(file) must stay Foundation-only")
            XCTAssertFalse(
                text.contains("import Combine"),
                "\(file) must stay Foundation-only")
        }
    }

    // MARK: The share-preview privacy contract, at the type level

    func testSharePreviewDeclaresOnlyTheShareableFields() throws {
        let text = try source("FLExplore/TableViewState.swift")
        guard let start = text.range(of: "struct SharePreview")?.lowerBound else {
            return XCTFail("TableViewState must declare SharePreview")
        }
        let rest = text[start...]
        guard let end = rest.range(of: "\n    }\n")?.lowerBound else {
            return XCTFail("could not locate SharePreview's body")
        }
        let body = String(rest[..<end])
        for allowed in ["recipeDisplay", "servingsDisplay", "swapsDisplay", "ratingDisplay", "noteDisplay"] {
            XCTAssertTrue(body.contains(allowed), "SharePreview must carry \(allowed)")
        }
        for banned in ["pantry", "health", "taste", "timestamp", "profile"] {
            XCTAssertFalse(
                body.lowercased().contains(banned),
                "SharePreview must not carry \(banned) — sharing previews exactly what leaves the phone")
        }
    }

    // MARK: The beta gate stays in state, not in the view

    func testTableEntryIsGatedByStateNotByViewLogic() throws {
        let state = try source("FLExplore/ExploreViewState.swift")
        XCTAssertTrue(
            state.contains("tablesEnabled"),
            "the beta flag must live in ExploreViewState")
        let view = try source("FLExplore/ExploreViews.swift")
        XCTAssertFalse(
            view.lowercased().contains("userdefaults"),
            "the beta flag must not be read from the view layer")
    }
}
