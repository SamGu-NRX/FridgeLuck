// FLDesignSystem — hit-region and row-geometry tests.
//
// The 44 pt floor is measured on RENDERED views, not asserted from source
// inspection: every pressable the package ships frames to at least
// Theme.minimumHitTarget in both axes, at the default Dynamic Type size and
// at an accessibility size (A3). ImageRenderer at scale 1 reports points,
// so the assertion is the real rendered geometry. The same harness pins the
// FLQuantityRow name behaviour: one line by default, wrapping at
// accessibility sizes. On Linux the file is inactive (no UIKit), like the
// render tests.
#if canImport(UIKit)
import XCTest
import SwiftUI
@testable import FLDesignSystem
import FLDesignTokens

@MainActor
final class HitRegionTests: XCTestCase {

    /// Renders a view at its ideal size and returns the size in points.
    private func renderedSize(_ view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "no image rendered")
        return image.size
    }

    private func withTypeSize(_ typeSize: DynamicTypeSize, _ view: some View) -> some View {
        view.environment(\.dynamicTypeSize, typeSize)
    }

    private func assertMeetsHitTarget(
        _ size: CGSize, _ name: String, at typeSize: DynamicTypeSize
    ) {
        let floor = CGFloat(Theme.minimumHitTarget)
        XCTAssertGreaterThanOrEqual(
            size.width, floor,
            "\(name) width \(size.width) at \(typeSize) is below the hit-target floor"
        )
        XCTAssertGreaterThanOrEqual(
            size.height, floor,
            "\(name) height \(size.height) at \(typeSize) is below the hit-target floor"
        )
    }

    func testTextButtonMeetsHitTargetAtDefaultAndAccessibilitySizes() throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let size = try renderedSize(withTypeSize(typeSize, FLButton(.text, "Undo") {}))
            assertMeetsHitTarget(size, "text button", at: typeSize)
        }
    }

    func testChipMeetsHitTargetAtDefaultAndAccessibilitySizes() throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for selected in [true, false] {
                let size = try renderedSize(
                    withTypeSize(typeSize, FLChip("Swap", isSelected: selected) {})
                )
                assertMeetsHitTarget(size, "chip selected: \(selected)", at: typeSize)
            }
        }
    }

    func testJudgementButtonsMeetHitTargetAtDefaultAndAccessibilitySizes() throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for title in ["Right", "Wrong", "Undo"] {
                let size = try renderedSize(
                    withTypeSize(typeSize, FLJudgementButton(title: title) {})
                )
                assertMeetsHitTarget(size, "judgement button \(title)", at: typeSize)
            }
        }
    }

    // MARK: FLQuantityRow name wrapping

    private let wrapTestName = "Fusilli al limone with the long title that cannot fit one line"

    private func quantityRowHeight(width: CGFloat, typeSize: DynamicTypeSize) throws -> CGFloat {
        try renderedSize(
            withTypeSize(
                typeSize,
                FLQuantityRow(name: wrapTestName, quantity: "200 g", state: .have)
            )
            .frame(width: width, alignment: .leading)
        ).height
    }

    func testQuantityRowNameWrapsAtAccessibilitySizes() throws {
        // Narrow proposal forces the long name to wrap; a wide one does not.
        // The height difference must exceed a text line — the row grows
        // instead of truncating the dish away.
        let wrapped = try quantityRowHeight(width: 300, typeSize: .accessibility5)
        let unwrapped = try quantityRowHeight(width: 1200, typeSize: .accessibility5)
        XCTAssertGreaterThan(
            wrapped - unwrapped, 10,
            "at accessibility sizes the name must wrap (wrapped \(wrapped), unwrapped \(unwrapped))"
        )
    }

    func testQuantityRowNameStaysOneLineByDefault() throws {
        // The default row grid caps the name at one line: the height is the
        // same whether the proposal is narrow or wide.
        let narrow = try quantityRowHeight(width: 200, typeSize: .large)
        let wide = try quantityRowHeight(width: 1200, typeSize: .large)
        XCTAssertEqual(
            narrow, wide, accuracy: 1,
            "at the default size the name stays on one line (narrow \(narrow), wide \(wide))"
        )
    }
}
#endif
