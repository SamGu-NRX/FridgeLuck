import XCTest
@testable import FLSubstitutions

/// Compound ingredients must be classed by what they ARE: soy sauce is soy
/// AND wheat; pesto is tree nuts AND dairy. Refusals must follow.
final class CompoundAllergenTests: XCTestCase {
    func testSoySauceCarriesSoyAndGluten() throws {
        let table = try Fixtures.table()
        let key = try table.resolveIngredientKey("soy sauce")
        let classes = Set(try XCTUnwrap(table.ingredient(key)).classes)
        XCTAssertTrue(classes.contains(.soy))
        XCTAssertTrue(classes.contains(.gluten), "brewed shoyu contains wheat")
    }

    func testPestoCarriesTreeNutsAndDairy() throws {
        let table = try Fixtures.table()
        let key = try table.resolveIngredientKey("pesto")
        let classes = Set(try XCTUnwrap(table.ingredient(key)).classes)
        XCTAssertTrue(classes.contains(.treeNut), "pesto contains pine nuts")
        XCTAssertTrue(classes.contains(.dairy), "traditional pesto contains parmesan")
    }

    func testGlutenFreeEaterIsNeverOfferedAGlutenBearingSoySauceSubstitute() throws {
        let table = try Fixtures.table()
        let candidates = try table.swapCandidates(for: "soy sauce", role: .umami, restrictions: ["gluten-free"])
        XCTAssertFalse(candidates.isEmpty, "soy sauce should have umami candidates")

        for candidate in candidates where candidate.recheck.substituteClasses.contains(.gluten) {
            XCTAssertTrue(candidate.isRefused, "\(candidate.pair.id) offered despite gluten")
            XCTAssertEqual(candidate.recheck.violated, [.gluten])
        }
        for candidate in try table.swaps(for: "soy sauce", role: .umami, restrictions: ["gluten-free"]) {
            XCTAssertFalse(candidate.recheck.substituteClasses.contains(.gluten))
        }

        // Tamari is the honest fix for a wheat allergy: accepted, and the
        // recheck shows the gluten class leaving, not appearing.
        let accepted = try table.swaps(for: "soy sauce", role: .umami, restrictions: ["gluten-free"])
        let tamari = try XCTUnwrap(
            accepted.first { $0.pair.id == "soy-sauce-umami-to-tamari" },
            "tamari swap missing for gluten-free eater"
        )
        XCTAssertTrue(tamari.recheck.removed.contains(.gluten))
        XCTAssertTrue(tamari.recheck.introduced.isEmpty)
        XCTAssertFalse(tamari.isRefused)
    }

    func testCoconutAminosIntroducingTreeNutsIsRefusedForNutFreeEater() throws {
        let table = try Fixtures.table()
        // Coconut aminos is a classic "soy sauce alternative" — and coconut
        // is classed tree_nut, so a nut-free eater must not see it offered.
        let candidates = try table.swapCandidates(for: "soy sauce", role: .umami, restrictions: ["nut-free"])
        let coconutAminos = try XCTUnwrap(
            candidates.first { $0.pair.id == "soy-sauce-umami-to-coconut-aminos" },
            "coconut-aminos pair missing"
        )
        XCTAssertTrue(coconutAminos.isRefused)
        XCTAssertTrue(coconutAminos.recheck.violated.contains(.treeNut))
        XCTAssertTrue(coconutAminos.recheck.introduced.contains(.treeNut))

        let accepted = try table.swaps(for: "soy sauce", role: .umami, restrictions: ["nut-free"])
        XCTAssertFalse(accepted.contains { $0.pair.id == "soy-sauce-umami-to-coconut-aminos" })
    }

    func testFishSauceToSoySauceIsRefusedForGlutenFreeEaterBecauseTheSubstituteIsCompound() throws {
        let table = try Fixtures.table()
        let candidates = try table.swapCandidates(for: "fish sauce", role: .umami, restrictions: ["gluten-free"])
        let soySauceSwap = try XCTUnwrap(
            candidates.first { $0.pair.id == "fish-sauce-umami-to-soy-sauce" },
            "fish-sauce-to-soy-sauce pair missing"
        )
        XCTAssertTrue(soySauceSwap.isRefused)
        XCTAssertEqual(soySauceSwap.recheck.violated, [.gluten])

        let accepted = try table.swaps(for: "fish sauce", role: .umami, restrictions: ["gluten-free"])
        XCTAssertFalse(accepted.contains { $0.pair.id == "fish-sauce-umami-to-soy-sauce" })
    }

    func testMaggiSeasoningIsRefusedForGlutenFreeEater() throws {
        let table = try Fixtures.table()
        // Maggi seasoning carries wheat (gluten) and soy.
        let candidates = try table.swapCandidates(for: "soy sauce", role: .umami, restrictions: ["gluten-free"])
        let maggi = candidates.first { $0.pair.id == "soy-sauce-umami-to-maggi-seasoning" }
        let candidate = try XCTUnwrap(maggi, "maggi pair missing")
        XCTAssertTrue(candidate.isRefused)
        XCTAssertTrue(candidate.recheck.violated.contains(.gluten))
    }

    func testVeganEaterIsNeverOfferedADairySubstituteForButter() throws {
        let table = try Fixtures.table()
        let candidates = try table.swapCandidates(for: "butter", role: .fat, restrictions: ["vegan"])
        XCTAssertFalse(candidates.isEmpty)
        for candidate in candidates where candidate.recheck.substituteClasses.contains(.dairy) {
            XCTAssertTrue(candidate.isRefused, "\(candidate.pair.id) offered to a vegan eater")
        }
    }
}
