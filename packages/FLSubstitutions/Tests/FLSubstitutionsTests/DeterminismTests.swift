import XCTest
@testable import FLSubstitutions

/// Same inputs -> same ranked output, every time. Two independent table
/// loads must produce byte-identical candidate serializations.
final class DeterminismTests: XCTestCase {
    func testTwoIndependentRunsAreByteIdentical() throws {
        let first = try Fixtures.table()
        let second = try Fixtures.table()

        var firstRun: [String] = []
        var secondRun: [String] = []
        firstRun.append("restriction-names|" + first.restrictionNames.joined(separator: ","))
        secondRun.append("restriction-names|" + second.restrictionNames.joined(separator: ","))

        for name in Fixtures.lookupBattery(first) {
            for role in Role.allCases {
                for restrictions in Fixtures.restrictionBatteries {
                    let a = try first.swapCandidates(for: name, role: role, restrictions: restrictions)
                    let b = try second.swapCandidates(for: name, role: role, restrictions: restrictions)
                    firstRun.append(Fixtures.canonical(a))
                    secondRun.append(Fixtures.canonical(b))
                }
            }
        }
        for name in Fixtures.lookupBattery(first) {
            for restrictions in Fixtures.restrictionBatteries {
                firstRun.append(Fixtures.canonical(try first.verifiedSwaps(for: name, restrictions: restrictions)))
                secondRun.append(Fixtures.canonical(try second.verifiedSwaps(for: name, restrictions: restrictions)))
            }
        }

        XCTAssertEqual(
            firstRun.joined(separator: "\n"),
            secondRun.joined(separator: "\n")
        )
    }

    func testRepeatedLookupsOnOneInstanceAreStable() throws {
        let table = try Fixtures.table()
        for name in Fixtures.lookupBattery(table) {
            for role in Role.allCases {
                let baseline = Fixtures.canonical(try table.swapCandidates(for: name, role: role, restrictions: ["vegan"]))
                for _ in 0..<3 {
                    XCTAssertEqual(
                        Fixtures.canonical(try table.swapCandidates(for: name, role: role, restrictions: ["vegan"])),
                        baseline
                    )
                }
            }
        }
    }
}

/// The table's class vocabulary and restriction semantics must stay exactly
/// aligned with the Suite C contract (evaluation/suites/recipes/allergens.json
/// on eval/scorecard-runner; S-CONTRACT in the source registry).
final class SuiteCContractTests: XCTestCase {
    func testSharedClassVocabularyMatchesTheContract() throws {
        let table = try Fixtures.table()
        let contract: Set<AllergenClass> = [
            .gluten, .dairy, .egg, .soy, .peanut, .treeNut, .sesame, .fish, .shellfish,
        ]
        XCTAssertEqual(Set(table.sharedAllergenClasses), contract)
    }

    func testAllergenFreeRestrictionsForbidExactlyTheirContractClass() throws {
        let table = try Fixtures.table()
        func forbids(_ name: String) throws -> Set<AllergenClass> {
            Set(try XCTUnwrap(table.restrictions[name], name).forbids)
        }
        XCTAssertEqual(try forbids("gluten-free"), [.gluten])
        XCTAssertEqual(try forbids("dairy-free"), [.dairy])
        XCTAssertEqual(try forbids("egg-free"), [.egg])
        XCTAssertEqual(try forbids("soy-free"), [.soy])
        XCTAssertEqual(try forbids("sesame-free"), [.sesame])
        XCTAssertEqual(try forbids("fish-free"), [.fish])
        XCTAssertEqual(try forbids("shellfish-free"), [.shellfish])
        XCTAssertEqual(try forbids("peanut-free"), [.peanut])
        XCTAssertEqual(try forbids("tree-nut-free"), [.treeNut])
        XCTAssertEqual(try forbids("nut-free"), [.treeNut, .peanut])
    }

    func testDietClaimsFollowTheContractForbidSets() throws {
        let table = try Fixtures.table()
        let flesh: Set<AllergenClass> = [
            .meatPoultry, .meatGround, .meatWholeCutPork, .meatWholeCutRed, .fleshFish, .fleshShellfish,
        ]
        XCTAssertEqual(Set(try XCTUnwrap(table.restrictions["vegetarian"], "vegetarian").forbids), flesh)
        XCTAssertEqual(
            Set(try XCTUnwrap(table.restrictions["vegan"], "vegan").forbids),
            flesh.union([.dairy, .egg, .honey])
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(table.restrictions["pescatarian"], "pescatarian").forbids),
            [.meatPoultry, .meatGround, .meatWholeCutPork, .meatWholeCutRed]
        )
    }

    func testCompoundAssignmentsMatchTheContractExamples() throws {
        let table = try Fixtures.table()
        XCTAssertEqual(Set(try XCTUnwrap(table.ingredient("soy_sauce")).classes), [.soy, .gluten])
        XCTAssertEqual(
            Set(try XCTUnwrap(table.ingredient("pesto")).classes),
            [.animalProduct, .dairy, .treeNut]
        )
    }
}
