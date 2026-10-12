import XCTest
@testable import FLIngredientFacts

final class SmokeTests: XCTestCase {
    func testRestrictionUnion() throws {
        let a = FLRestrictions(allergens: [.soy], diets: [.vegetarian])
        let b = FLRestrictions(allergens: [.milk], diets: [.glutenFree])
        let union = FLRestrictions.union([a, b])
        XCTAssertEqual(union.allergens, [.soy, .milk])
        XCTAssertEqual(union.diets, [.vegetarian, .glutenFree])
    }
}
