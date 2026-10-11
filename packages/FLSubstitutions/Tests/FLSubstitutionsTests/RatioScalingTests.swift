import XCTest
@testable import FLSubstitutions

/// Ratio scaling and macro-delta arithmetic, shown as real math against the
/// USDA per-100 g values recorded in the table.
final class RatioScalingTests: XCTestCase {
    func testEggsToApplesauceByCups() throws {
        let table = try Fixtures.table()
        let pair = try Fixtures.pair(table, id: "egg-binder-to-applesauce")
        XCTAssertEqual(pair.ratio.basis, "quarter-cup-per-egg")
        XCTAssertEqual(pair.ratio.value, 1.0, accuracy: 0.0001)

        // The math, shown: 2 eggs x 1/4 cup per egg = 1/2 cup applesauce.
        let eggs = 2.0
        let quarterCupsPerEgg = pair.ratio.value * 0.25
        XCTAssertEqual(eggs * quarterCupsPerEgg, 0.5, accuracy: 0.0001)

        // Kitchen-unit bases are never silently converted to grams.
        let candidate = try table.swapCandidates(for: "egg", role: .binder, restrictions: [])
            .first { $0.pair.id == pair.id }
        XCTAssertNil(candidate?.scaledSubstituteGrams(originalGrams: 50))

        // Macro direction sanity: fruit puree loses the egg's protein and
        // sodium and adds moisture carbs.
        let delta = try XCTUnwrap(pair.macroDelta)
        XCTAssertLessThan(delta.proteinG, 0)
        XCTAssertLessThan(delta.sodiumMg, 0)
        XCTAssertGreaterThan(delta.carbsG, 0)
    }

    func testEggToMashedBananaWeightMathWithRecordedConflict() throws {
        let table = try Fixtures.table()
        let pair = try Fixtures.pair(table, id: "egg-binder-to-mashed-banana")
        XCTAssertEqual(pair.ratio.basis, "weight")
        XCTAssertEqual(pair.ratio.value, 1.2, accuracy: 0.0001)

        // 1 large egg is about 50 g -> 60 g mashed banana.
        let candidate = try table.swapCandidates(for: "egg", role: .binder, restrictions: [])
            .first { $0.pair.id == pair.id }
        let scaled = try XCTUnwrap(candidate?.scaledSubstituteGrams(originalGrams: 50))
        XCTAssertEqual(scaled, 60.0, accuracy: 0.01)

        // The shipped 0.6 ratio conflicts with the supported ~1.2: the swap
        // ranks plausible, never verified.
        XCTAssertEqual(candidate?.verdict, .plausible)
        XCTAssertNotNil(pair.ratio.conflictWith)
    }

    /// Every computable macro delta must reproduce from the table's own USDA
    /// per-100 g values: delta = substitute(typical x ratio g) - original(typical g),
    /// kcal rounded to integers and the rest to one decimal.
    func testEveryMacroDeltaReproducesFromUSDAValues() throws {
        let table = try Fixtures.table()
        var checked = 0
        for pair in table.pairs {
            guard let delta = pair.macroDelta, let typical = pair.typicalAmountG else { continue }
            let original = try XCTUnwrap(table.ingredient(pair.original), pair.id)
            let substitute = try XCTUnwrap(table.ingredient(pair.substitute), pair.id)
            let om = try XCTUnwrap(original.macrosPer100g, "\(pair.id): original macros missing")
            let sm = try XCTUnwrap(substitute.macrosPer100g, "\(pair.id): substitute macros missing")
            let subG = typical * pair.ratio.value

            func check(_ recorded: Double, _ actual: Double, _ tolerance: Double, _ nutrient: String) {
                XCTAssertEqual(recorded, actual, accuracy: tolerance, "\(pair.id) macro \(nutrient)")
            }
            check(delta.kcal, sm.kcal * subG / 100 - om.kcal * typical / 100, 0.51, "kcal")
            check(delta.proteinG, sm.proteinG * subG / 100 - om.proteinG * typical / 100, 0.11, "protein_g")
            check(delta.carbsG, sm.carbsG * subG / 100 - om.carbsG * typical / 100, 0.11, "carbs_g")
            check(delta.fatG, sm.fatG * subG / 100 - om.fatG * typical / 100, 0.11, "fat_g")
            check(delta.fiberG, sm.fiberG * subG / 100 - om.fiberG * typical / 100, 0.11, "fiber_g")
            check(delta.sugarG, sm.sugarG * subG / 100 - om.sugarG * typical / 100, 0.11, "sugar_g")
            check(delta.sodiumMg, sm.sodiumMg * subG / 100 - om.sodiumMg * typical / 100, 0.11, "sodium_mg")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 150, "most pairs should carry a computable delta")
    }

    func testNullMacroDeltasAlwaysExplainThemselves() throws {
        let table = try Fixtures.table()
        for pair in table.pairs where pair.macroDelta == nil {
            XCTAssertFalse(
                (pair.macroDeltaNullReason ?? "").isEmpty,
                "pair \(pair.id): null macro delta without a reason"
            )
        }
    }
}
