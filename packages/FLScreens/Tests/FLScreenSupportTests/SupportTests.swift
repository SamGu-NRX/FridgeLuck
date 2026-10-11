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

    func testProvisionalMappingTripwire() {
        // DELIBERATE TRIPWIRE. While the base branch carries no H/P palette
        // tables, both variants resolve to the same table and
        // `isProvisional` is true. When the base lands the H and P tables
        // (PR #96 follow-up), this test FAILS ON PURPOSE: re-point
        // `FLRenderPaletteMapping.palette(for:in:)` at the real tables,
        // flip `isProvisional` to false, and update this assertion.
        XCTAssertTrue(
            FLRenderPaletteMapping.isProvisional,
            "H/P palette tables have landed upstream — the render matrix must now resolve real per-variant tables"
        )
        for scheme in FLDesignTokens.ColorScheme.allCases {
            XCTAssertEqual(
                FLRenderPaletteMapping.palette(for: .h, in: scheme),
                FLRenderPaletteMapping.palette(for: .p, in: scheme),
                "the provisional mapping resolves both variants to the same table"
            )
        }
    }
}
