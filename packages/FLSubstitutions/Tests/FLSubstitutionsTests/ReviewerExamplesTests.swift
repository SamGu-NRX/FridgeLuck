import FLIngredientFacts
import XCTest
@testable import FLSubstitutions

/// The PR #114 BLOCK review's examples, as first-class named cases. Each test
/// pins the REVIEWER'S scenario end to end: the verdict, the refusal layer
/// that fires, and the offer list the eater actually sees.
final class ReviewerExamplesTests: XCTestCase {
    private func candidateNamed(
        _ table: SubstitutionTable, id: String,
        original: String, role: Role, restrictions: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> SwapCandidate {
        let candidates = try table.swapCandidates(for: original, role: role, restrictions: restrictions)
        return try XCTUnwrap(
            candidates.first { $0.pair.id == id },
            "\(id) missing among candidates for \(original)/\(role) [\(restrictions.joined(separator: ","))]",
            file: file, line: line
        )
    }

    // MARK: blocker (a) — lard offered to vegan/vegetarian eaters

    func testLardIsRefusedForVegetarianAndVeganEaters() throws {
        let table = try Fixtures.table()
        for eater in ["vegetarian", "vegan"] {
            let swap = try candidateNamed(
                table, id: "shortening-fat-to-lard",
                original: "shortening", role: .fat, restrictions: [eater]
            )
            XCTAssertTrue(swap.isRefused, "\(eater): lard not refused")
            XCTAssertNil(swap.recheck.conditionalRefusal, "\(eater): refusal must come from the facts store")
            guard case .violated(let reason) = swap.recheck.outcome else {
                return XCTFail("\(eater): expected a settled store violation, got \(swap.recheck.outcome)")
            }
            XCTAssertFalse(reason.isEmpty, "\(eater): the violation reason must name the offending component")

            let offered = try table.swaps(for: "shortening", role: .fat, restrictions: [eater])
            XCTAssertFalse(offered.contains { $0.pair.id == "shortening-fat-to-lard" }, "\(eater): lard offered")

            // The unrestricted verdict is untouched: lard works as shortening.
            let plain = try candidateNamed(
                table, id: "shortening-fat-to-lard", original: "shortening", role: .fat, restrictions: []
            )
            XCTAssertFalse(plain.isRefused)
        }
    }

    func testWorcestershireIsRefusedForVegetarianAndVeganEaters() throws {
        let table = try Fixtures.table()
        for eater in ["vegetarian", "vegan"] {
            let swap = try candidateNamed(
                table, id: "anchovy-umami-to-worcestershire",
                original: "anchovy", role: .umami, restrictions: [eater]
            )
            XCTAssertTrue(swap.isRefused, "\(eater): worcestershire not refused")
            guard case .violated = swap.recheck.outcome else {
                return XCTFail("\(eater): expected a settled store violation, got \(swap.recheck.outcome)")
            }
            let offered = try table.swaps(for: "anchovy", role: .umami, restrictions: [eater])
            XCTAssertFalse(
                offered.contains { $0.pair.id == "anchovy-umami-to-worcestershire" },
                "\(eater): worcestershire offered"
            )
        }
    }

    // MARK: blocker (b) — generic tamari for gluten-free eaters

    func testGenericTamariIsAskTheUserForGlutenFreeEaters() throws {
        let table = try Fixtures.table()
        let swap = try candidateNamed(
            table, id: "soy-sauce-umami-to-tamari",
            original: "soy sauce", role: .umami, restrictions: ["gluten-free"]
        )
        // Not a settled violation — composition is UNKNOWN: the ask-user path.
        XCTAssertTrue(swap.isRefused, "generic tamari offered to a gluten-free eater")
        XCTAssertTrue(swap.needsConfirmation, "tamari's unknown gluten must surface as ask-the-user")
        XCTAssertNil(swap.recheck.conditionalRefusal, "refusal must come from the facts store, not a failure row")
        guard case .askUser(let reasons) = swap.recheck.outcome else {
            return XCTFail("expected ask-user for tamari's unknown gluten, got \(swap.recheck.outcome)")
        }
        XCTAssertTrue(
            reasons.contains { $0.lowercased().contains("tamari") },
            "the ask-user reasons should name the ingredient: \(reasons)"
        )
        let offered = try table.swaps(for: "soy sauce", role: .umami, restrictions: ["gluten-free"])
        XCTAssertFalse(offered.contains { $0.pair.id == "soy-sauce-umami-to-tamari" })
        // A note to read the bottle cannot substitute for the recheck: the
        // record's note stays, but the OFFER decision is fail-closed.
        XCTAssertTrue(
            (table.ingredient("tamari")?.allergenNote ?? "").lowercased().contains("unknown"),
            "the tamari record must keep its composition-unknown note"
        )
    }

    func testCertifiedGlutenFreeTamariIsADistinctProductFormWithLabelEvidence() throws {
        let table = try Fixtures.table()
        let store = try XCTUnwrap(table.factsStore, "the canonical facts store must load")
        // The generic ingredient stays unknown for gluten...
        guard case .unknown = store.evaluate(ingredient: "tamari", restrictions: FLRestrictions(allergens: [], diets: [.glutenFree])) else {
            return XCTFail("generic tamari must evaluate unknown for gluten-free")
        }
        // ...while the certified product form carries LABEL evidence and allows.
        guard case .allowed = store.evaluate(
            ingredient: "certified gluten-free tamari",
            restrictions: FLRestrictions(allergens: [], diets: [.glutenFree])
        ) else {
            return XCTFail("the certified gluten-free product form must evaluate allowed on label evidence")
        }
    }

    // MARK: ask-the-user when a substitute is missing from the registry

    func testSubstituteMissingFromTheFactsRegistryYieldsAskTheUserAndIsNeverOffered() throws {
        let table = try Fixtures.table()
        let store = try XCTUnwrap(table.factsStore)
        // A pair whose substitute resolves to no canonical facts record.
        let missing = table.pairs.first { pair in
            guard let substitute = table.ingredient(pair.substitute) else { return false }
            let name = substitute.factsKey ?? substitute.display
            return store.resolve(name) == nil
        }
        let pair = try XCTUnwrap(missing, "no pair exercises the missing-registry path — the suite is blind to it")
        for eater in ["vegan", "gluten-free", "dairy-free"] {
            let candidates = try table.swapCandidates(
                for: pair.original, role: pair.role, restrictions: [eater]
            )
            let candidate = try XCTUnwrap(candidates.first { $0.pair.id == pair.id })
            XCTAssertTrue(candidate.needsConfirmation, "\(pair.id) [\(eater)]: missing facts must ask the user")
            XCTAssertTrue(candidate.isRefused, "\(pair.id) [\(eater)]: offered without facts")
            let offered = try table.swaps(for: pair.original, role: pair.role, restrictions: [eater])
            XCTAssertFalse(offered.contains { $0.pair.id == pair.id }, "\(pair.id) [\(eater)] offered")
        }
    }

    // MARK: review finding (c) — household unions

    func testTwoEatersRestrictionsUnionScreenBothAxes() throws {
        let table = try Fixtures.table()
        // The reviewer's example: two eaters' restrictions union — milk +
        // peanut means BOTH are screened. The mapping folds them into one
        // FLRestrictions carrying both axes.
        let set = try RestrictionSet(names: ["dairy-free", "peanut-free"], table: table)
        // dairy-free is a diet axis in the canonical vocabulary; peanut-free
        // screens the peanuts allergen.
        XCTAssertTrue(set.fl.diets.contains(.dairyFree))
        XCTAssertTrue(set.fl.allergens.contains(.peanuts))

        // Behaviorally, with the pairs the table actually has: the union
        // dairy-free + gluten-free must refuse a dairy substitute AND a
        // gluten substitute, screening both axes in one lookup.
        let dairyPair = try XCTUnwrap(
            table.pairs.first { p in
                table.ingredient(p.substitute)?.classes.contains(.dairy) == true
            },
            "no pair substitutes a dairy ingredient"
        )
        let glutenPair = try XCTUnwrap(
            table.pairs.first { p in
                table.ingredient(p.substitute)?.classes.contains(.gluten) == true
            },
            "no pair substitutes a gluten ingredient"
        )
        let union = ["dairy-free", "gluten-free"]
        for (pair, axis) in [(dairyPair, AllergenClass.dairy), (glutenPair, AllergenClass.gluten)] {
            let candidates = try table.swapCandidates(
                for: pair.original, role: pair.role, restrictions: union
            )
            let candidate = try XCTUnwrap(candidates.first { $0.pair.id == pair.id })
            XCTAssertTrue(candidate.isRefused, "\(pair.id): offered to the union household")
            XCTAssertTrue(
                candidate.recheck.violated.contains(axis) || candidate.recheck.outcome.isOfferable == false,
                "\(pair.id): the union must screen \(axis.rawValue)"
            )
        }
    }

    // MARK: review finding (e) — conditional rows vs functional failures

    func testSeitanAsProteinIsRefusedOnlyForGlutenFreeEaters() throws {
        let table = try Fixtures.table()
        // The conditional row: chicken-to-seitan works as protein for everyone
        // EXCEPT gluten-free eaters; the refusal must not change the verdict.
        let pair = try Fixtures.pair(table, id: "chicken-protein-to-seitan")
        let unrestricted = try candidateNamed(
            table, id: "chicken-protein-to-seitan",
            original: pair.original, role: .protein, restrictions: []
        )
        XCTAssertFalse(unrestricted.isRefused, "seitan should be offered when nobody avoids gluten")
        XCTAssertEqual(unrestricted.verdict, .plausible, "the convention-sourced ratio keeps the swap plausible")

        let gf = try candidateNamed(
            table, id: "chicken-protein-to-seitan",
            original: pair.original, role: .protein, restrictions: ["gluten-free"]
        )
        XCTAssertTrue(gf.isRefused, "seitan must be refused for gluten-free eaters")
        XCTAssertNotNil(gf.recheck.conditionalRefusal, "the refusal must come from the conditional failure row")
        XCTAssertEqual(gf.verdict, .plausible, "a conditional refusal must not degrade the context verdict")

        let offered = try table.swaps(for: pair.original, role: .protein, restrictions: ["gluten-free"])
        XCTAssertFalse(offered.contains { $0.pair.id == "chicken-protein-to-seitan" })
    }

    // MARK: review finding (f) — a supported role never inherits the primary ratio

    func testAlternativeRolesNeverScaleWithThePrimaryRatio() throws {
        let table = try Fixtures.table()
        // Every pair with a supported_also role: the alternative role must
        // expose ONLY its own recorded ratio (nil when none is evidenced),
        // and scaling must refuse to run off the primary ratio.
        var exercised = 0
        for pair in table.pairs where !pair.supportedAlso.isEmpty {
            let also = try XCTUnwrap(pair.supportedAlso.first, "\(pair.id): fixture lacks supported_also")
            let candidates = try table.swapCandidates(for: pair.original, role: also.role, restrictions: [])
            let candidate = try XCTUnwrap(candidates.first { $0.pair.id == pair.id })
            XCTAssertEqual(candidate.ratio(for: also.role)?.value, also.ratio?.value)
            XCTAssertEqual(
                candidate.ratio(for: also.role)?.basis, also.ratio?.basis
            )
            if also.ratio == nil {
                XCTAssertNil(candidate.scaledSubstituteGrams(originalGrams: 100, role: also.role))
            } else if also.ratio?.basis == "weight", let value = also.ratio?.value {
                let scaled = try XCTUnwrap(candidate.scaledSubstituteGrams(originalGrams: 100, role: also.role))
                XCTAssertEqual(scaled, 100 * value, accuracy: 0.0001)
            }
            exercised += 1
        }
        XCTAssertGreaterThan(exercised, 0, "no pair exercises supported_also — the suite is blind to it")
    }
}
