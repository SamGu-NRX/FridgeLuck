// FLDesignTokens tests — Direction H/P token contracts beyond the contrast
// claims: the kitchen-pill fills, P's adjusted text hexes, the shell/photo
// layout tokens, and the base-palette bridge a direction swap consumes.

import XCTest
@testable import FLDesignTokens

final class DirectionTokensTests: XCTestCase {

    // MARK: WCAG machinery (same implementation as the contrast suites)

    private func linear(_ channel: Double) -> Double {
        if channel <= 0.03928 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ color: ColorToken) -> Double {
        0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    private func contrast(_ foreground: ColorToken, _ background: ColorToken) -> Double {
        let lf = luminance(foreground)
        let lb = luminance(background)
        return (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
    }

    // MARK: Kitchen pills (H)

    /// H's kitchen pills are fills that must (a) carry ink text at AA body
    /// level, (b) read as a shape against both grounds (package floor
    /// 1.15:1 — WCAG defines no fill-vs-ground floor, so the package pins
    /// one), and (c) keep the idle > gone lightness hierarchy so "gone"
    /// reads more recessed. Light pills are warm (R > G > B) per the
    /// linen-tinted mandate.
    func testDirectionHKitchenPillFillsMeetFillAndMarkerFloors() {
        let cases: [(mode: DirectionMode, idle: ColorToken, gone: ColorToken, ink: ColorToken, bg: ColorToken, surface: ColorToken, warm: Bool)] = [
            (mode: .light, idle: DirectionH.light.pillIdle, gone: DirectionH.light.pillGone,
             ink: DirectionH.light.ink, bg: DirectionH.light.bg, surface: DirectionH.light.surface, warm: true),
            (mode: .dark, idle: DirectionH.dark.pillIdle, gone: DirectionH.dark.pillGone,
             ink: DirectionH.dark.ink, bg: DirectionH.dark.bg, surface: DirectionH.dark.surface, warm: false),
        ]
        for item in cases {
            XCTAssert(
                contrast(item.ink, item.idle) >= 4.5,
                "\(item.mode.rawValue) ink on pillIdle computes \(String(format: "%.2f", contrast(item.ink, item.idle))), floor 4.5"
            )
            XCTAssert(
                contrast(item.ink, item.gone) >= 4.5,
                "\(item.mode.rawValue) ink on pillGone computes \(String(format: "%.2f", contrast(item.ink, item.gone))), floor 4.5"
            )
            for (groundName, ground) in [("bg", item.bg), ("surface", item.surface)] {
                XCTAssert(
                    contrast(item.idle, ground) >= 1.15,
                    "\(item.mode.rawValue) pillIdle vs \(groundName) computes \(String(format: "%.2f", contrast(item.idle, ground))), package floor 1.15"
                )
                XCTAssert(
                    contrast(item.gone, ground) >= 1.15,
                    "\(item.mode.rawValue) pillGone vs \(groundName) computes \(String(format: "%.2f", contrast(item.gone, ground))), package floor 1.15"
                )
            }
            XCTAssert(
                luminance(item.idle) > luminance(item.gone),
                "\(item.mode.rawValue) pillIdle must read lighter (less recessed) than pillGone"
            )
            if item.warm {
                XCTAssert(
                    item.idle.red > item.idle.green && item.idle.green > item.idle.blue,
                    "light pillIdle must be warm (R > G > B), linen-tinted"
                )
                XCTAssert(
                    item.gone.red > item.gone.green && item.gone.green > item.gone.blue,
                    "light pillGone must be warm (R > G > B), linen-tinted"
                )
            }
        }
    }

    // MARK: P's adjusted text hexes

    /// P's four derived text roles land on the direction doc's canonical
    /// adjusted hexes, verbatim (light mode — the round that adjusted them).
    func testDirectionPDerivedTextRolesMatchTheAdjustedHexes() {
        XCTAssertEqual(DirectionP.light.ink2.hexString, "#6B6054", "textSecondary adjusted hex")
        XCTAssertEqual(DirectionP.light.accentInk.hexString, "#A35131", "accentInk adjusted hex")
        XCTAssertEqual(DirectionP.light.sageInk.hexString, "#5F6E53", "sageInk adjusted hex")
        XCTAssertEqual(DirectionP.light.oatInk.hexString, "#7C5C30", "oatInk adjusted hex")
    }

    // MARK: Layout tokens (shell/photo rules)

    /// The shell/photo rules are tokens: 3:2 photo frames, photo height
    /// capped at 40% of the container. Each direction publishes its own
    /// layout token block as the theme-swap unit; today they agree with
    /// F's because the task pins these values for every direction.
    func testLayoutTokensCarryTheShellPhotoRules() {
        let theme = Theme.layout
        XCTAssertEqual(theme.photoAspectRatio, 1.5, accuracy: 0.0001, "photo frames are 3:2")
        XCTAssertEqual(theme.photoMaxHeightFraction, 0.4, accuracy: 0.0001, "photo height cap is 40%")
        XCTAssertEqual(DirectionH.layout, theme, "H's layout token block is the swap unit")
        XCTAssertEqual(DirectionP.layout, theme, "P's layout token block is the swap unit")
        // A 300 pt wide frame lays out 200 pt tall at 3:2.
        XCTAssertEqual(300.0 / theme.photoAspectRatio, 200.0, accuracy: 0.0001)
    }

    // MARK: Base-palette bridge

    /// A direction swap hands FLDesignSystem a ten-role Palette: the accent
    /// takes the yolk seat, accentSoft the wash, accentInk the text-on-wash.
    /// Every mode of both directions must resolve all ten roles from its own
    /// tokens.
    func testDirectionBasePaletteBridgeResolvesTheTenRoles() {
        let roles: [(ColorRole, KeyPath<HPalette, ColorToken>, KeyPath<PPalette, ColorToken>)] = [
            (.bg, \.bg, \.bg),
            (.ink, \.ink, \.ink),
            (.ink2, \.ink2, \.ink2),
            (.ink3, \.ink3, \.ink3),
            (.rule, \.rule, \.rule),
            (.rule2, \.rule2, \.rule2),
            (.yolk, \.accent, \.accent),
            (.yolkSoft, \.accentSoft, \.accentSoft),
            (.yolkInk, \.accentInk, \.accentInk),
            (.error, \.error, \.error),
        ]
        for mode in DirectionMode.allCases {
            let h = DirectionH.palette(mode)
            let p = DirectionP.palette(mode)
            for (role, hPath, pPath) in roles {
                XCTAssertEqual(h.basePalette.token(role), h[keyPath: hPath], "H \(mode.rawValue) bridge \(role.rawValue)")
                XCTAssertEqual(p.basePalette.token(role), p[keyPath: pPath], "P \(mode.rawValue) bridge \(role.rawValue)")
            }
        }
    }
}
