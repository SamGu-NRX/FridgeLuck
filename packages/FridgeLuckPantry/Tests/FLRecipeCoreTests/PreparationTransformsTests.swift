import XCTest
import FLDomain
@testable import FLRecipeCore

/// The preparation compatibility matrix: deliberately conservative. Raw stock
/// can become any declared knife-work form; anything else is exact-match only,
/// because assuming a transform the pantry cannot prove would overclaim.
final class PreparationTransformsTests: XCTestCase {
    let standard = FLPreparationTransforms.standard

    func testRawStockServesDeclaredKnifeWorkForms() {
        XCTAssertTrue(standard.lotUsable(forLine: "chopped", lotPreparation: nil))
        XCTAssertTrue(standard.lotUsable(forLine: "grated", lotPreparation: nil))
        XCTAssertTrue(standard.lotUsable(forLine: "finely chopped", lotPreparation: nil))
    }

    func testRawLinesNeedRawStock() {
        XCTAssertFalse(standard.lotUsable(forLine: nil, lotPreparation: "chopped"), "chopped onions cannot be un-chopped")
        XCTAssertFalse(standard.lotUsable(forLine: nil, lotPreparation: "cooked"))
        XCTAssertTrue(standard.lotUsable(forLine: nil, lotPreparation: nil))
    }

    func testSameFormAlwaysServes() {
        XCTAssertTrue(standard.lotUsable(forLine: "cooked", lotPreparation: "cooked"))
        XCTAssertTrue(standard.lotUsable(forLine: nil, lotPreparation: nil))
    }

    func testUnknownFormsAreExactMatchOnly() {
        XCTAssertFalse(standard.lotUsable(forLine: "roasted", lotPreparation: nil), "'roasted' is not knife work")
        XCTAssertFalse(standard.lotUsable(forLine: "roasted", lotPreparation: "cooked"))
        XCTAssertTrue(standard.lotUsable(forLine: "roasted", lotPreparation: "roasted"))
    }

    func testFormsAreNormalizedCaseAndWhitespace() throws {
        let transforms = try FLPreparationTransforms(knifeWork: ["  Diced ", "SLICED"])
        XCTAssertTrue(transforms.knifeWork.contains("diced"))
        XCTAssertTrue(transforms.knifeWork.contains("sliced"))
        XCTAssertEqual(transforms.knifeWork.count, 2)
        XCTAssertTrue(transforms.lotUsable(forLine: "Sliced ", lotPreparation: "  "))
        XCTAssertThrowsError(try FLPreparationTransforms(knifeWork: ["   "]))
    }
}
