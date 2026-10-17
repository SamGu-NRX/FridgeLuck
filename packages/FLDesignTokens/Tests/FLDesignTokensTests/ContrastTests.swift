// FLDesignTokens tests — WCAG 2.1 contrast.
//
// Relative luminance and the contrast ratio are implemented HERE, in the
// test target, on top of the public tokens: the package never imports a
// platform colour framework, so the test computes straight from the sRGB
// channels exactly the way WCAG 2.1 defines it.
//
// Each assertion checks the computed ratio against the value the design
// direction claims, within 0.1. When a computed ratio disagrees by more than
// 0.1 the test FAILS and prints computed vs claimed — whoever holds the doc
// then corrects the doc claim (or the token value), and the pair in
// `docClaims` below is updated to match.
//
// Known discrepancy at authoring time: the doc claims "ink on paper 17:1"
// but #131313 on #F7F8F6 computes to 17.44. The doc's own rule is that
// contrast checks are "computed, not estimated"; 17.44 rounds to 17.4, so the
// recorded claim below is 17.4 and the doc line should read "17.4:1" after
// the correction. (All other claims compute within 0.1 as written.)

import XCTest
@testable import FLDesignTokens

final class ContrastTests: XCTestCase {

    // MARK: WCAG 2.1 machinery (test-target implementation)

    /// WCAG 2.1 §1.4.3 channel transfer function. The 0.03928 threshold is
    /// the constant WCAG 2.1 specifies; every channel in FridgeLuck's tokens
    /// sits far above both it and the 0.04045 variant, so the choice cannot
    /// move any ratio here.
    private func linear(_ channel: Double) -> Double {
        if channel <= 0.03928 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance: L = 0.2126·R + 0.7152·G + 0.0722·B on linearised channels.
    private func luminance(_ color: ColorToken) -> Double {
        0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    /// Contrast ratio, larger value first: (L1 + 0.05) / (L2 + 0.05).
    private func contrast(_ foreground: ColorToken, _ background: ColorToken) -> Double {
        let lf = luminance(foreground)
        let lb = luminance(background)
        return (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
    }

    // MARK: The doc's claims

    private struct Claim {
        let pair: String
        let foreground: ColorRole
        let background: ColorRole
        let scheme: ColorScheme
        /// The ratio as printed in design-direction.md.
        let docClaim: Double
        /// The ratio this suite asserts (docClaim unless the computed value
        /// fell outside ±0.1 — see the ink/paper note in the header).
        let asserted: Double
    }

    private static let docClaims: [Claim] = [
        Claim(pair: "ink on paper", foreground: .ink, background: .bg, scheme: .paper,
              docClaim: 17.0, asserted: 17.4),
        Claim(pair: "ink2 on paper", foreground: .ink2, background: .bg, scheme: .paper,
              docClaim: 6.1, asserted: 6.1),
        Claim(pair: "ink3 on paper", foreground: .ink3, background: .bg, scheme: .paper,
              docClaim: 3.2, asserted: 3.2),
        Claim(pair: "ink on yolk", foreground: .ink, background: .yolk, scheme: .paper,
              docClaim: 11.3, asserted: 11.3),
        Claim(pair: "yolk on hob", foreground: .yolk, background: .bg, scheme: .hob,
              docClaim: 11.9, asserted: 11.9),
        Claim(pair: "yolkInk on yolkSoft", foreground: .yolkInk, background: .yolkSoft, scheme: .paper,
              docClaim: 6.6, asserted: 6.6),
        Claim(pair: "error on paper", foreground: .error, background: .bg, scheme: .paper,
              docClaim: 5.0, asserted: 5.0),
    ]

    // MARK: Tests

    func testDocumentedContrastClaimsWithinTenth() {
        let tolerance = 0.1
        var failures: [String] = []

        for claim in Self.docClaims {
            let foreground = Theme.color(claim.foreground, in: claim.scheme)
            let background = Theme.color(claim.background, in: claim.scheme)
            let computed = contrast(foreground, background)
            let line = String(
                format: "%@: claimed %.1f, computed %.2f (delta %+.2f) [%@ %@ %@]",
                claim.pair, claim.docClaim, computed, computed - claim.docClaim,
                claim.foreground.rawValue, claim.background.rawValue, claim.scheme.rawValue
            )
            print("contrast | \(line)")
            if abs(computed - claim.asserted) > tolerance {
                failures.append("\(line) — outside ±0.1 of the asserted claim \(claim.asserted)")
            }
        }

        // Always surface the computed-vs-claimed table; when it disagrees the
        // failure names the pair so the doc claim can be corrected.
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testInkPaperDiscrepancyIsRecordedForDocCorrection() {
        // Guards the one known doc discrepancy: the doc's "17:1" understates
        // the computed 17.44. If this test starts failing because the tokens
        // changed, re-derive `asserted` for the ink/pair claim above.
        let ink = Theme.color(.ink, in: .paper)
        let paper = Theme.color(.bg, in: .paper)
        let computed = contrast(ink, paper)
        XCTAssertEqual(computed, 17.44, accuracy: 0.005,
                       "ink/paper moved — update the ContrastTests docClaims table and the doc claim")
        XCTAssertNotEqual(computed, 17.0,
                          "if ink/paper ever computes to exactly 17.0 the doc claim becomes correct; update both")
    }

    // MARK: Craft-rule floors for the palettes this package defines

    func testBodyTextContrastFloorsHoldInEveryScheme() {
        // SPEC §5 craft rule: contrast is at least 4.5:1 for body text.
        // Body-size roles are ink (primary) and ink2 (secondary); ink3 is
        // explicitly never body-size. Yolk-ink on yolk-soft is a text pair.
        for scheme in ColorScheme.allCases {
            let palette = Theme.palette(scheme)
            for (role, token) in [("ink", palette.ink), ("ink2", palette.ink2)] {
                let ratio = contrast(token, palette.bg)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(role) on \(scheme.rawValue) is body text and must reach 4.5:1 (got \(ratio))"
                )
            }
        }
        // The yolk-soft text pairing must stay readable in the two schemes
        // that use a wash behind text (paper's light wash and dark/hob's dark wash).
        for scheme in ColorScheme.allCases {
            let palette = Theme.palette(scheme)
            let ratio = contrast(palette.yolkInk, palette.yolkSoft)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "yolkInk on yolkSoft in \(scheme.rawValue) is body-size text (got \(ratio))"
            )
        }
    }

    func testDarkPaletteHonoursThePaperInversionRule() {
        // dark is "the paper palette inverted": figure and ground must swap
        // lightness (ink darker than bg on paper; lighter than bg on dark).
        let paper = Theme.palette(.paper)
        let dark = Theme.palette(.dark)
        XCTAssertGreaterThan(
            luminance(paper.bg), luminance(paper.ink),
            "paper: background must be lighter than ink"
        )
        XCTAssertGreaterThan(
            luminance(dark.ink), luminance(dark.bg),
            "dark: ink must be lighter than background (the inversion)"
        )
        // The chromatic tokens keep their meaning: yolk identical, wash/error
        // take the hob values tuned for a dark ground.
        XCTAssertEqual(dark.yolk, paper.yolk, "yolk keeps its value in dark")
        XCTAssertEqual(dark.yolkSoft, Theme.color(.yolkSoft, in: .hob))
        XCTAssertEqual(dark.yolkInk, Theme.color(.yolkInk, in: .hob))
        XCTAssertEqual(dark.error, Theme.color(.error, in: .hob))
    }

    // MARK: Component text roles — the actual uses, with the opacities applied

    /// One meaningful text use in a shipped component: the role it applies,
    /// the surface it sits on, the scheme it runs in, and any opacity the
    /// component lays over the text. Contrast is checked per USE, not per
    /// nominal pair — a role that is compliant in one component and dimmed
    /// in another fails here.
    private struct ComponentTextUse {
        let use: String
        let textRole: ColorRole
        let background: ColorRole
        let scheme: ColorScheme
        /// Opacity the component applies to this text over its background
        /// (1.0 = none). The effective colour is the alpha blend — what the
        /// eye actually receives.
        let opacity: Double

        init(use: String, textRole: ColorRole, background: ColorRole,
             scheme: ColorScheme, opacity: Double = 1.0) {
            self.use = use
            self.textRole = textRole
            self.background = background
            self.scheme = scheme
            self.opacity = opacity
        }
    }

    private static let componentTextUses: [ComponentTextUse] = [
        // FLTimerTile — cook mode: digits, caption label, Paused label on hob bg.
        ComponentTextUse(use: "FLTimerTile digits", textRole: .yolk, background: .bg, scheme: .hob),
        ComponentTextUse(use: "FLTimerTile caption label", textRole: .ink2, background: .bg, scheme: .hob),
        ComponentTextUse(use: "FLTimerTile Paused label", textRole: .ink2, background: .bg, scheme: .hob),
        // FLCookCard — who·when caption and the note quote.
        ComponentTextUse(use: "FLCookCard who·when caption", textRole: .ink2, background: .bg, scheme: .paper),
        ComponentTextUse(use: "FLCookCard note quote", textRole: .ink, background: .bg, scheme: .paper),
        // FLTasteSentence — evidence count and the rejected sentence (no dim).
        ComponentTextUse(use: "FLTasteSentence evidence count", textRole: .ink2, background: .bg, scheme: .paper),
        ComponentTextUse(use: "FLTasteSentence rejected sentence", textRole: .ink2, background: .bg, scheme: .paper),
        // FLChip — both states in both ambient schemes.
        ComponentTextUse(use: "FLChip selected", textRole: .yolkInk, background: .yolkSoft, scheme: .paper),
        ComponentTextUse(use: "FLChip selected (dark)", textRole: .yolkInk, background: .yolkSoft, scheme: .dark),
        ComponentTextUse(use: "FLChip unselected", textRole: .ink2, background: .bg, scheme: .paper),
        // FLButton — the filled label and the chrome-less text-button label.
        ComponentTextUse(use: "FLButton primary label", textRole: .bg, background: .ink, scheme: .paper),
        ComponentTextUse(use: "FLButton text label", textRole: .ink, background: .bg, scheme: .paper),
        // Rows, meters, section labels.
        ComponentTextUse(use: "FLQuantityRow quantity", textRole: .ink2, background: .bg, scheme: .paper),
        ComponentTextUse(use: "FLFitMeter count", textRole: .ink, background: .bg, scheme: .paper),
        ComponentTextUse(use: "FLFitMeter swaps", textRole: .ink2, background: .bg, scheme: .paper),
        ComponentTextUse(use: "FLSectionLabel", textRole: .ink2, background: .bg, scheme: .paper),
    ]

    func testComponentTextRolesMeetSmallTextFloor() {
        var failures: [String] = []
        for use in Self.componentTextUses {
            let fg = Theme.color(use.textRole, in: use.scheme)
            let bg = Theme.color(use.background, in: use.scheme)
            // Alpha-blend the text over its background at the component's
            // applied opacity — a dim cannot hide behind the nominal pair.
            let blended = ColorToken(
                red: fg.red * use.opacity + bg.red * (1 - use.opacity),
                green: fg.green * use.opacity + bg.green * (1 - use.opacity),
                blue: fg.blue * use.opacity + bg.blue * (1 - use.opacity)
            )
            let ratio = contrast(blended, bg)
            let line = String(format: "%@: %.2f:1 (floor 4.5)", use.use, ratio)
            print("contrast | component-role | \(line)")
            if ratio < 4.5 { failures.append(line) }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
