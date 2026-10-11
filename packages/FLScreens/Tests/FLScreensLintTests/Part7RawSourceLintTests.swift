// FLScreens lint tests — Part 7 additions, in the Part 2–6 lint suite's
// conventions.
//
// Parts 2–6 linted each module's own files as that module landed. Part 7
// is the CROSS-SCREEN pass: these tests assert the invariants across all
// twelve screen modules in ONE place, so a future screen cannot quietly
// break the discipline the per-part lints established:
//
// - Colour, type and radius flow through the theme in every screen view
//   (Theme.swiftColor / .flType / Radius). FLShellView is exempt: it is
//   pure system chrome (TabView/Tab) by design — the system restyles it.
// - No file outside the palette bridge names DirectionH or DirectionP.
//   The bridge is exactly three places: FLDesignTokens's own tables (the
//   other package), FLDesignSystem's ThemeBridge (the token→SwiftUI
//   conversion point), and FLScreenSupport's FLPaletteVariant (the
//   FLRenderPaletteMapping). Screens build against the theme and never a
//   direction-specific type.
// - Photo geometry flows only through PhotoLayoutRule: no screen file
//   hand-rolls the reference numbers (852, the 300 pt width) or a raw
//   3:2 ratio; the screen-top heroes all make the ONE shared
//   `heroIdealHeight` call; in-card areas use the shared aspect ratio.
//   LeChef's cook-surface viewfinder keeps its RECORDED Part 5
//   exemption — it is not a photo area (a photo-layout rule on the cook
//   surface means someone drew a photo there), so its raw 3:2 is the one
//   allowed occurrence, and this suite pins that it stays the only one.
// - The scroll roots share the family rhythm: 16 pt top, 24 pt bottom
//   (the Parts 2–5 root; Part 7 audited Part 6's screens onto it).
// - Every screen title carries the header accessibility trait, so the
//   hierarchy the type roles draw (.screenTitle above FLSectionLabel)
//   is also the hierarchy assistive tech reads.
// - The passive tag family is one grammar: Capsule on the soft accent
//   fill with the family 8/4 padding — no per-screen corner-radius
//   literals, and the row state glyph matches FLQuantityRow's grammar.
// - Loading states use the shared FLEmptyLoadingLine — no screen draws
//   its own progress line.

import XCTest

final class Part7RawSourceLintTests: XCTestCase {

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

    /// Every .swift file under Sources, as paths relative to Sources/.
    private var allSources: [String] {
        let base = packageRoot.appendingPathComponent("Sources")
        var paths: [String] = []
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let element = enumerator?.nextObject() {
            guard let url = element as? URL, url.pathExtension == "swift" else { continue }
            paths.append(String(url.path.dropFirst(base.path.count + 1)))
        }
        return paths.sorted()
    }

    /// A file's code with // line comments stripped, so a lint note that
    /// quotes a banned literal does not trip its own rule.
    private func code(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { line in
                if let range = line.range(of: "//") {
                    return String(line[..<range.lowerBound])
                }
                return line
            }
            .joined(separator: "\n")
    }

    // MARK: The file inventory (Part 7's cross-screen set)

    /// Every screen view file — the themed surfaces. FLShellView is not
    /// here: it is pure system chrome (see header).
    private let screenViewFiles = [
        "FLTonight/TonightViews.swift",
        "FLKitchen/KitchenViews.swift",
        "FLKitchen/ShellSKitchenViews.swift",
        "FLExplore/ExploreViews.swift",
        "FLExplore/TableViews.swift",
        "FLRecipe/RecipeViews.swift",
        "FLScan/ScanViews.swift",
        "FLTasteProfile/TasteViews.swift",
        "FLLeChef/LeChefViews.swift",
        "FLProgress/ProgressViews.swift",
        "FLQuests/QuestsViews.swift",
        "FLTour/TourViews.swift",
    ]

    /// The scroll-root files: the screens whose content scrolls from the
    /// very top. LeChef's surfaces are full-height stands (idle, paused,
    /// complete) with their own top padding of 16 but no scroll root.
    private let scrollRootFiles = [
        "FLTonight/TonightViews.swift",
        "FLKitchen/KitchenViews.swift",
        "FLExplore/ExploreViews.swift",
        "FLExplore/TableViews.swift",
        "FLRecipe/RecipeViews.swift",
        "FLScan/ScanViews.swift",
        "FLTasteProfile/TasteViews.swift",
        "FLProgress/ProgressViews.swift",
        "FLQuests/QuestsViews.swift",
    ]

    /// The screen-top hero photo sites (the 40%-cap's reason: Tonight's
    /// primary action stays above the tab bar on first paint).
    private let heroPhotoFiles = [
        "FLTonight/TonightViews.swift",
        "FLRecipe/RecipeViews.swift",
        "FLScan/ScanViews.swift",
        "FLTour/TourViews.swift",
    ]

    /// The in-card photo sites (3:2 at the container width; the cap binds
    /// screen-top heroes, not cards).
    private let inCardPhotoFiles = [
        "FLExplore/ExploreViews.swift",
        "FLExplore/TableViews.swift",
        "FLRecipe/RecipeViews.swift",
    ]

    /// The one file allowed to name the visual directions inside this
    /// package: the variant → palette-table mapping.
    private let directionBridgeFile = "FLScreenSupport/FLPaletteVariant.swift"

    // MARK: Theme discipline, across all modules at once

    func testEveryScreenViewBuildsOnTheTheme() throws {
        // Files that DRAW a shape must take its radius through the closed
        // Radius set. Two files draw none and are exempt from that one
        // check — ShellSKitchenViews is a pure composition (background,
        // one quiet link row, the embedded unmodified KitchenView) and
        // ProgressViews delegates every card shape to the shared
        // components — and both stay bound by the numeric-radius ban
        // below, so a shape added later cannot enter as a literal.
        let drawsNoShape = Set([
            "FLKitchen/ShellSKitchenViews.swift",
            "FLProgress/ProgressViews.swift",
        ])
        for file in screenViewFiles {
            let text = try source(file)
            XCTAssertTrue(
                text.contains("Theme.swiftColor"),
                "\(file) must take every colour through Theme.swiftColor")
            XCTAssertTrue(
                text.contains(".flType("),
                "\(file) must take every type through .flType")
            if !drawsNoShape.contains(file) {
                XCTAssertTrue(
                    text.contains("Radius."),
                    "\(file) must take every radius through the Radius set")
            }
        }
    }

    func testNoFileOutsideThePaletteBridgeNamesADirection() throws {
        for path in allSources where path != directionBridgeFile {
            let text = try source(path)
            for name in ["DirectionH", "DirectionP"] {
                XCTAssertFalse(
                    text.contains(name),
                    "\(path) names \(name) — directions are resolved by the "
                        + "palette bridge (FLRenderPaletteMapping) and the "
                        + "ThemeBridge; screens never see the type")
            }
        }
    }

    // MARK: Photo geometry, one rule

    func testNoScreenFileHandRollsPhotoGeometry() throws {
        for path in allSources where path != "FLScreenSupport/PhotoLayoutRule.swift" {
            let body = code(try source(path))
            for literal in ["852", "forWidth: 300", "aspectRatio(3.0 / 2.0)"] {
                if path.hasSuffix("LeChefViews.swift") && literal == "aspectRatio(3.0 / 2.0)" {
                    // The recorded Part 5 exemption: the cook-surface
                    // viewfinder is not a photo area.
                    continue
                }
                XCTAssertFalse(
                    body.contains(literal),
                    "\(path) hand-rolls photo geometry (\"\(literal)\") — "
                        + "photo layout flows only through PhotoLayoutRule")
            }
        }
    }

    func testHeroPhotosUseTheOneSharedDerivation() throws {
        for file in heroPhotoFiles {
            let text = try source(file)
            XCTAssertTrue(
                text.contains("PhotoLayoutRule.heroIdealHeight"),
                "\(file) must derive its hero height through the shared "
                    + "heroIdealHeight (Part 7 audit: per-site derivations "
                    + "double-capped and drifted)")
        }
    }

    func testInCardPhotosUseTheSharedRatio() throws {
        for file in inCardPhotoFiles {
            let text = try source(file)
            XCTAssertTrue(
                text.contains(".aspectRatio(CGFloat(PhotoLayoutRule.aspectRatio)"),
                "\(file) must draw its in-card photo areas at the shared "
                    + "3:2 ratio (PhotoLayoutRule.aspectRatio)")
        }
    }

    // MARK: Spacing rhythm, across all scroll roots

    func testScrollRootsShareTheFamilyRhythm() throws {
        for file in scrollRootFiles {
            let text = try source(file)
            XCTAssertTrue(
                text.range(
                    of: "\\.padding\\(\\.top, 16\\)\\s*\\n\\s*\\.padding\\(\\.bottom, 24\\)",
                    options: .regularExpression
                ) != nil,
                "\(file) must open its scroll root at the family rhythm — "
                    + "16 pt top, 24 pt bottom (Part 7 audit aligned the "
                    + "Part 6 roots and Explore's feed to it)")
        }
    }

    // MARK: Heading hierarchy, across all screens

    func testScreenTitlesAreMarkedAsHeaders() throws {
        for file in screenViewFiles where file != "FLKitchen/ShellSKitchenViews.swift" {
            let text = try source(file)
            XCTAssertTrue(
                text.contains(".accessibilityAddTraits(.isHeader)"),
                "\(file) must mark its screen title as an accessibility "
                    + "header — the .screenTitle level of the hierarchy, "
                    + "above the section labels")
        }
    }

    func testExploreCarriesTheMockMatchedTitle() throws {
        // Part 3 recorded "the mock's decorative gradient header becomes a
        // plain large-title header" — Part 7 found the view had dropped
        // the title entirely (the mock's h1 is "Explore"). Pinned.
        let text = try source("FLExplore/ExploreViews.swift")
        XCTAssertTrue(text.contains("Text(\"Explore\")"))
        XCTAssertTrue(text.contains(".flType(.screenTitle)"))
        XCTAssertTrue(text.contains(".accessibilityIdentifier(\"fl.explore.title\")"))
    }

    // MARK: Tag and glyph grammars

    func testTagGrammarIsTheCapsuleFamily() throws {
        // The passive tag: Capsule on the soft accent fill, the family
        // 8/4 padding (Tonight's use-soon, Kitchen's leftover, Taste's
        // evidence — Part 7 audited Taste onto the family).
        for file in ["FLTonight/TonightViews.swift", "FLTasteProfile/TasteViews.swift"] {
            let text = try source(file)
            XCTAssertTrue(
                text.contains("Capsule().fill(Theme.swiftColor(.yolkSoft"),
                "\(file) draws a passive tag — it belongs to the Capsule "
                    + "tag family, not a per-screen corner radius")
        }
    }

    func testNoScreenFileCarriesANumericCornerRadius() throws {
        for path in allSources {
            let body = code(try source(path))
            XCTAssertNil(
                body.range(of: "cornerRadius: [0-9]", options: .regularExpression),
                "\(path) carries a numeric corner radius — radii come from "
                    + "the closed Radius set, never a literal")
        }
    }

    func testKitchenGlyphMatchesTheQuantityRowGrammar() throws {
        // Same screen, one glyph grammar: Kitchen's state squares are
        // FLQuantityRow's grammar (square, dash [2, 2]) at row size.
        let text = try source("FLKitchen/KitchenViews.swift")
        XCTAssertTrue(text.contains("dash: [2, 2]"), "the unconfirmed glyph rides FLQuantityRow's dash")
        XCTAssertTrue(text.contains("case .confirmed:\n                Rectangle()"), "the confirmed glyph is the square (Radius.row)")
    }

    // MARK: Loading grammar

    func testLoadingStatesUseTheSharedLine() throws {
        // Every screen with a host-fetch state shows the SAME loading
        // line (Part 7 audit: Scan's analysing surface drew its own).
        for file in ["FLExplore/ExploreViews.swift", "FLExplore/TableViews.swift",
                     "FLLeChef/LeChefViews.swift", "FLScan/ScanViews.swift"] {
            let text = try source(file)
            XCTAssertTrue(
                text.contains("FLEmptyLoadingLine"),
                "\(file) shows a loading state — it must use the shared "
                    + "FLEmptyLoadingLine, not a hand-drawn line")
        }
        for path in allSources where path != "FLScreenSupport/PhotoLayoutRule.swift" {
            let body = code(try source(path))
            XCTAssertFalse(
                body.contains(".frame(height: 2)"),
                "\(path) draws its own thin line — loading goes through "
                    + "FLEmptyLoadingLine; hairlines through the rule role")
        }
    }

    // MARK: The saved-food grammar, across the screens that show it

    func testSavedFoodIsFormattedOnlyThroughTheSharedLine() throws {
        // The two screens that render a saved-food count both do it via
        // FLSavedFoodLine — and the audit re-verified no other screen
        // formats grams at all (Table's "food saved" line is the host's
        // verbatim challenge text, never a derived number).
        for file in ["FLProgress/ProgressViewState.swift", "FLQuests/QuestsViewState.swift"] {
            let text = try source(file)
            XCTAssertTrue(
                text.contains("FLSavedFoodLine("),
                "\(file) renders a saved-food count — it must go through "
                    + "FLSavedFoodLine so the grammar cannot drift")
        }
    }
}
