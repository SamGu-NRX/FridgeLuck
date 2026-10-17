// FLDesignTokens tests — invariants.
// The direction doc's hard rules, encoded: minimum type size 13, the closed
// radius set with the 16–36 gap, exact density values, the five motion
// tokens with their durations, the motion scalars, and the haptic roles.

import XCTest
@testable import FLDesignTokens

final class InvariantTests: XCTestCase {

    // MARK: Type

    func testMinimumTypeSizeIsThirteenAnywhere() {
        for role in TypeRole.allCases {
            XCTAssertGreaterThanOrEqual(
                role.spec.size, 13,
                "\(role.rawValue) is \(role.spec.size)pt — minimum size anywhere is 13"
            )
            XCTAssertGreaterThanOrEqual(
                role.spec.lineHeight, role.spec.size,
                "\(role.rawValue) line height cannot be smaller than the size"
            )
        }
    }

    func testTypeRoleTableMatchesTheDirectionDoc() {
        let expected: [(TypeRole, TypeFace, Double, Double, Int, Double, Bool)] = [
            (.dishTitle, .sfProDisplay, 32, 34, 700, -0.02, false),
            (.screenTitle, .sfProDisplay, 28, 32, 700, -0.015, false),
            (.cookStep, .sfProDisplay, 26, 32, 600, -0.01, false),
            (.body, .sfProText, 17, 24, 400, 0, false),
            (.secondary, .sfProText, 15, 20, 400, 0, false),
            (.sectionLabel, .sfProText, 13, 16, 600, 0, false),
            (.caption, .sfProText, 13, 16, 400, 0, false),
            (.timer, .sfMono, 56, 56, 500, -0.02, true),
            (.fitCount, .sfMono, 17, 22, 500, -0.01, true),
            (.quantity, .sfMono, 15, 20, 400, -0.01, true),
            (.evidence, .sfMono, 13, 16, 400, 0, true),
        ]
        for (role, face, size, lineHeight, weight, tracking, mono) in expected {
            let spec = role.spec
            XCTAssertEqual(spec.face, face, "\(role.rawValue) face")
            XCTAssertEqual(spec.size, size, "\(role.rawValue) size")
            XCTAssertEqual(spec.lineHeight, lineHeight, "\(role.rawValue) line height")
            XCTAssertEqual(spec.weight, weight, "\(role.rawValue) weight")
            XCTAssertEqual(spec.trackingEm, tracking, accuracy: 0.0001, "\(role.rawValue) tracking")
            XCTAssertEqual(spec.isMonospaced, mono, "\(role.rawValue) monospaced")
        }
    }

    func testNumeralsAreMonoAndWordsAreNot() {
        let mono = TypeRole.allCases.filter { $0.spec.isMonospaced }
        XCTAssertEqual(
            Set(mono), [.timer, .fitCount, .quantity, .evidence],
            "exactly the numeral roles are monospaced"
        )
    }

    // MARK: Density

    func testDecidingDensityValues() {
        let d = Density.deciding
        XCTAssertEqual(d.sideMargin, 24)
        XCTAssertEqual(d.blockGap, 32)
        XCTAssertEqual(d.actionClearance, 48)
        XCTAssertNil(d.rowHeight, "deciding has no row grid")
        XCTAssertNil(d.rowInner)
        XCTAssertNil(d.chipGap)
        XCTAssertNil(d.sectionGap)
    }

    func testDenseDensityValues() {
        let d = Density.dense
        XCTAssertEqual(d.sideMargin, 20)
        XCTAssertEqual(d.blockGap, 24)
        XCTAssertNil(d.actionClearance, "dense has no action clearance")
        XCTAssertEqual(d.rowHeight, 44)
        XCTAssertEqual(d.rowInner, 12)
        XCTAssertEqual(d.chipGap, 8)
        XCTAssertEqual(d.sectionGap, 24)
    }

    // MARK: Radii

    func testRadiusSetIsClosedAndHasTheSixteenToThirtySixGap() {
        XCTAssertEqual(
            Set(Radius.allCases.map(\.rawValue)),
            [0, 10, 14, 36],
            "the radius set is exactly row 0, buttonOrChip 10, card 14, sheet 36"
        )
        for radius in Radius.allCases {
            let inForbiddenGap = radius.rawValue > 16 && radius.rawValue < 36
            XCTAssertFalse(
                inForbiddenGap,
                "radius \(radius.rawValue) falls in the forbidden 16–36 band"
            )
        }
    }

    // MARK: Motion

    func testMotionTokenDurationsAndBounces() {
        let expected: [(MotionToken, Double, Double?)] = [
            (.snap, 0.22, 0),
            (.move, 0.34, 0.12),
            (.settle, 0.50, 0.22),
            (.fade, 0.15, nil),
            (.none, 0, nil),
        ]
        for (token, duration, bounce) in expected {
            XCTAssertEqual(token.durationSeconds, duration, "\(token.rawValue) duration")
            XCTAssertEqual(token.bounce, bounce, "\(token.rawValue) bounce")
        }
        // Fade and none are not springs — bounce nil means exactly that.
        XCTAssertNil(MotionToken.fade.bounce)
        XCTAssertNil(MotionToken.none.bounce)
    }

    func testMotionScalars() {
        XCTAssertEqual(Theme.pressScale, 0.97)
        XCTAssertEqual(Theme.pressDurationMs, 120)
        XCTAssertEqual(Theme.reducedMotionFadeMs, 150)
        XCTAssertEqual(Theme.staggerMs, 40)
        XCTAssertEqual(Theme.staggerCap, 6)
        // The cap is a cap: stagger beyond six items never happens.
        XCTAssertGreaterThan(Theme.staggerCap, 0)
        XCTAssertGreaterThanOrEqual(Theme.pressScale, 0.9, "press feedback must stay perceptible")
        XCTAssertLessThan(Theme.pressScale, 1.0, "press feedback scales down, never up")
    }

    // MARK: Haptics

    func testHapticRoleSurfaces() {
        XCTAssertEqual(
            Set(HapticRole.lightConfirm.surfaces), ["confirm row", "chip"]
        )
        XCTAssertEqual(
            Set(HapticRole.mediumCommit.surfaces), ["add-to-kitchen", "cook-complete"]
        )
        XCTAssertEqual(
            Set(HapticRole.rigidTimerDone.surfaces), ["timer finished"]
        )
    }

    // MARK: ColorToken plumbing

    func testColorTokenHexPlumbing() {
        XCTAssertEqual(ColorToken(hex: 0xF7F8F6).hexString, "#F7F8F6")
        XCTAssertEqual(ColorToken(hex: "#131313"), ColorToken(red: 19 / 255.0, green: 19 / 255.0, blue: 19 / 255.0))
        XCTAssertNil(ColorToken(hex: "#13131"), "malformed hex is rejected, not coerced")
        XCTAssertNil(ColorToken(hex: "#13131G"))
        // Channels clamp instead of producing out-of-gamut values.
        XCTAssertEqual(ColorToken(red: 2, green: -1, blue: 0.5).hexString, "#FF0080")
    }
}
