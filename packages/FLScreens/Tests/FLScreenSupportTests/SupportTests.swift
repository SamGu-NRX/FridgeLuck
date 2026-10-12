// FLScreenSupport tests — the photo layout rule, the shell configuration,
// and the palette-variant mapping.

import XCTest
@testable import FLScreenSupport
import FLDesignTokens

final class SupportTests: XCTestCase {

    // MARK: Photo layout rule (Sam's round decision: 3:2, capped at 40%)

    func testPhotoHeightIsThreeTwoForTheWidth() {
        // A 345 pt wide photo (393 pt screen, 24 pt margins each side)
        // wants 345 / 1.5 = 230 pt of height.
        XCTAssertEqual(
            PhotoLayoutRule.height(forWidth: 345, availableHeight: 852),
            230, accuracy: 0.001
        )
    }

    func testPhotoHeightIsCappedAtFortyPercentOfAvailableHeight() {
        // A narrow, very tall context: the 3:2 ideal would exceed the cap.
        let height = PhotoLayoutRule.height(forWidth: 300, availableHeight: 400)
        XCTAssertEqual(height, 160, accuracy: 0.001, "40% of 400 is the cap")
    }

    func testPhotoCapIsExactlyFortyPercent() {
        XCTAssertEqual(PhotoLayoutRule.maxHeightFraction, 0.40)
    }

    func testPhotoAspectIsExactlyThreeTwo() {
        XCTAssertEqual(PhotoLayoutRule.aspectRatio, 1.5, accuracy: 0.0001)
    }

    func testDegenerateInputsYieldZero() {
        XCTAssertEqual(PhotoLayoutRule.height(forWidth: 0, availableHeight: 852), 0)
        XCTAssertEqual(PhotoLayoutRule.height(forWidth: 345, availableHeight: 0), 0)
        XCTAssertEqual(PhotoLayoutRule.height(forWidth: -1, availableHeight: 100), 0)
    }

    func testPhotoNeverEatsThePrimaryActionSpaceOnAPhoneScreen() {
        // On the reference phone (393 × 852), the photo must leave enough
        // room that the actions sit above the tab bar: cap + hero text is
        // well under half the screen. The cap is the enforced bound.
        let cap = 852 * PhotoLayoutRule.maxHeightFraction
        XCTAssertLessThanOrEqual(
            PhotoLayoutRule.height(forWidth: 345, availableHeight: 852), cap
        )
        XCTAssertLessThan(cap, 852 / 2)
    }

    // MARK: The shared hero derivation (Part 7 audit: one height, cap once)

    func testHeroIdealHeightIsTheThreeTwoIdealAtTheReferenceWidth() {
        // The single derivation every screen-top hero uses: 3:2 at the
        // reference width, so the scroll layout is stable and the four
        // hero sites (Tonight, Recipe, Scan, Tour) cannot drift.
        XCTAssertEqual(
            PhotoLayoutRule.heroIdealHeight,
            PhotoLayoutRule.referenceScreenWidth / PhotoLayoutRule.aspectRatio,
            accuracy: 0.001
        )
    }

    func testHeroIdealHeightIsCappedOnceAgainstTheReferenceScreen() {
        // The cap is applied exactly once, against the reference SCREEN
        // height — never against the photo frame's own height (the
        // double-cap the Part 7 audit removed). 40% of 852 is 340.8, well
        // above the 200 pt ideal, so the ideal is the binding value and
        // the hero renders at 3:2.
        let cap = PhotoLayoutRule.referenceScreenHeight * PhotoLayoutRule.maxHeightFraction
        XCTAssertEqual(PhotoLayoutRule.heroIdealHeight, 200, accuracy: 0.001)
        XCTAssertLessThanOrEqual(PhotoLayoutRule.heroIdealHeight, cap)
        XCTAssertEqual(
            PhotoLayoutRule.heroIdealHeight,
            PhotoLayoutRule.height(
                forWidth: PhotoLayoutRule.referenceScreenWidth,
                availableHeight: PhotoLayoutRule.referenceScreenHeight
            ),
            accuracy: 0.001
        )
    }

    // MARK: Shell configuration (Sam's round decision)

    func testStandardShellIsFourTabsPlusTrailingSearchRoleScan() {
        let shell = FLShellConfiguration.standard
        XCTAssertEqual(shell.tabs.map(\.id), ["tonight", "kitchen", "explore", "cookbook", "scan"])
        XCTAssertEqual(shell.tabs.last?.role, .search, "Scan is the trailing search-role tab")
        XCTAssertEqual(shell.scanPlacement, .searchRoleTab)
        // No Table tab: Table lives inside Explore behind its beta flag.
        XCTAssertFalse(shell.tabs.contains { $0.id == "table" })
    }

    func testStandardShellHasNoTableTab() {
        let shell = FLShellConfiguration.standard
        XCTAssertEqual(
            Set(shell.tabs.map(\.id).dropLast()),
            ["tonight", "kitchen", "explore", "cookbook"]
        )
    }

    func testShellSIsTwoTabsPlusTheNativeScanAccessory() {
        let shell = FLShellConfiguration.shellS
        XCTAssertEqual(shell.tabs.map(\.id), ["kitchen", "progress"])
        XCTAssertEqual(shell.scanPlacement, .bottomAccessory)
    }

    func testScanSearchTabCarriesCustomLabelAndIcon() {
        let scan = FLShellTab.scanSearchTab
        XCTAssertEqual(scan.title, "Scan")
        XCTAssertEqual(scan.systemImage, "viewfinder")
        XCTAssertEqual(scan.role, .search)
    }

    // MARK: Palette variants (the H/P render matrix)

    func testEveryVariantResolvesAPaletteForEveryScheme() {
        for variant in FLPaletteVariant.allCases {
            for scheme in FLDesignTokens.ColorScheme.allCases {
                let palette = FLRenderPaletteMapping.palette(for: variant, in: scheme)
                for role in FLDesignTokens.ColorRole.allCases {
                    // Totality: every role resolves without trapping.
                    _ = palette.token(role)
                }
            }
        }
    }

    func testLandedMappingResolvesRealTables() {
        // LANDED. The base branch carries the real H and P palette tables
        // (DirectionH.swift / DirectionP.swift), so the mapping resolves
        // each variant to its own table. This is the landed counterpart of
        // the former provisional tripwire: the tripwire asserted both
        // variants collapsed to one table; the landed state asserts they
        // differ, and that pills come from the direction tables rather
        // than the F-mode defaults.
        XCTAssertFalse(
            FLRenderPaletteMapping.isProvisional,
            "the mapping must resolve the real per-variant tables now that they have landed"
        )
        for scheme in FLDesignTokens.ColorScheme.allCases {
            XCTAssertNotEqual(
                FLRenderPaletteMapping.palette(for: .h, in: scheme),
                FLRenderPaletteMapping.palette(for: .p, in: scheme),
                "H and P must resolve to different tables per scheme"
            )
        }
        // H's pills come from H's own tested table.
        XCTAssertEqual(
            FLRenderPaletteMapping.palette(for: .h, in: .paper).pillIdle,
            FLDesignTokens.DirectionH.palette(.light).pillIdle,
            "H pills ride H's canonical pill fills"
        )
        // P's pills map to P's own chip/surface fills (P's canonical tables
        // define no pill fills yet — see the mapping's documentation).
        XCTAssertEqual(
            FLRenderPaletteMapping.palette(for: .p, in: .paper).pillIdle,
            FLDesignTokens.DirectionP.light.oatChip,
            "P pills ride P's own AA-tested chip fills"
        )
    }
}
