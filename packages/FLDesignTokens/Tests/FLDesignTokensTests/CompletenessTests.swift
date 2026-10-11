// FLDesignTokens tests — completeness.
// Every role name the design direction names must exist; a missing role is
// rejected with a list of what is gone. Renames surface as both "missing"
// and "unexpected" so nobody silently re-keys the system.

import XCTest
@testable import FLDesignTokens

final class CompletenessTests: XCTestCase {

    func testColourRolesComplete() {
        let expected = [
            "bg", "ink", "ink2", "ink3", "rule", "rule2",
            "yolk", "yolkSoft", "yolkInk", "error",
        ]

        let actual = ColorRole.allCases.map(\.rawValue)

        let missing = Set(expected).subtracting(actual).sorted()
        let unexpected = Set(actual).subtracting(expected).sorted()

        XCTAssertTrue(
            missing.isEmpty,
            "Missing colour roles (add them to ColorRole and Theme.palette): "
                + missing.joined(separator: ", ")
        )
        XCTAssertTrue(
            unexpected.isEmpty,
            "Unexpected colour roles (update the expected list or remove the role): "
                + unexpected.joined(separator: ", ")
        )
        XCTAssertEqual(actual.count, expected.count)
    }

    func testEveryColourRoleResolvesInEveryScheme() {
        for scheme in ColorScheme.allCases {
            let palette = Theme.palette(scheme)
            for role in ColorRole.allCases {
                let token = palette.token(role)
                XCTAssertFalse(
                    token.hexString.isEmpty,
                    "\(role.rawValue) failed to resolve in \(scheme.rawValue)"
                )
            }
        }
    }

    func testTypeRolesComplete() {
        let expected = [
            "dishTitle", "screenTitle", "cookStep", "body", "secondary",
            "sectionLabel", "caption", "timer", "fitCount", "quantity", "evidence",
        ]
        let actual = TypeRole.allCases.map(\.rawValue)
        let missing = Set(expected).subtracting(actual).sorted()
        let unexpected = Set(actual).subtracting(expected).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "Missing type roles: " + missing.joined(separator: ", ")
        )
        XCTAssertTrue(
            unexpected.isEmpty,
            "Unexpected type roles: " + unexpected.joined(separator: ", ")
        )
    }

    func testMotionTokensComplete() {
        let expected = ["snap", "move", "settle", "fade", "none"]
        let actual = MotionToken.allCases.map(\.rawValue)
        let missing = Set(expected).subtracting(actual)
        XCTAssertTrue(
            missing.isEmpty,
            "Missing motion tokens: " + missing.joined(separator: ", ")
        )
    }

    func testHapticRolesComplete() {
        let expected = ["lightConfirm", "mediumCommit", "rigidTimerDone"]
        let actual = HapticRole.allCases.map(\.rawValue)
        let missing = Set(expected).subtracting(actual)
        XCTAssertTrue(
            missing.isEmpty,
            "Missing haptic roles: " + missing.joined(separator: ", ")
        )
    }

    func testDensitySystemsComplete() {
        // Both systems must exist and neither may leak the other's measures.
        for (name, density) in [("deciding", Density.deciding), ("dense", Density.dense)] {
            XCTAssertGreaterThan(density.sideMargin, 0, "\(name) needs a side margin")
            XCTAssertGreaterThan(density.blockGap, 0, "\(name) needs a block gap")
        }
    }
}
