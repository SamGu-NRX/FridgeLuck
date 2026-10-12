import XCTest
@testable import FLFlowCore
import FLDomain

/// The dinner decision: hard filters never weakened, explainable options,
/// honest fit lines, explicit Tonight states, and the rejection policy that
/// never turns "something else" into a dislike.
final class DinnerDecisionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func context(servings: Int = 2, restrictions: [Restriction] = []) throws -> MealContext {
        let eaters: [Eater]
        if restrictions.isEmpty {
            eaters = [Eater(name: nil, restriction: TestBuilders.restriction())]
        } else {
            eaters = restrictions.map { Eater(name: "eater", restriction: $0) }
        }
        return try MealContext(eaters: eaters, servings: servings)
    }

    private func pantry(_ lines: [FlowPantryLine], staples: Set<String> = ["olive oil", "salt"]) -> PantryView {
        let policy = try! PantryPolicy(stapleNames: staples, stalenessHorizonSeconds: 14 * 24 * 3600)
        return PantryView(lines: lines, policy: policy, now: t0)
    }

    // MARK: Hard filters

    func testAllergenCandidateIsNeverProposed() throws {
        let satay = TestBuilders.revision("satay", lines: [
            TestBuilders.line("l1", "peanut sauce", TestBuilders.grams(100)),
        ])
        let candidates = [(revision: satay, claims: RecipeClaims(allergensByIngredient: ["peanut sauce": [.peanuts]]))]
        let view = pantry([TestBuilders.pantryLine("peanut sauce", TestBuilders.grams(500), confirmedAt: t0)])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(restrictions: [TestBuilders.restriction(allergens: [.peanuts])]),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .nothingFeasible, "an allergen conflict is a release blocker, never an option")
        XCTAssertTrue(proposal.options.isEmpty)
    }

    // MARK: Review round 2, blocker 1 — composition checks fail closed

    func testMissingAllergenCompositionFailsClosed() throws {
        // A milk-free household and a candidate whose claims carry NO entry
        // for cream cheese: its composition is unresolved. An unresolved
        // check must never pass a restriction — "not declared" is not
        // "carries nothing" (round 2, blocker 1).
        let bake = TestBuilders.revision("bake", lines: [
            TestBuilders.line("l1", "potato", TestBuilders.grams(300)),
            TestBuilders.line("l2", "cream cheese", TestBuilders.grams(100)),
        ])
        // Only potato's composition is resolved; cream cheese is missing
        // on purpose.
        let candidates = [(revision: bake, claims: RecipeClaims(allergensByIngredient: ["potato": []]))]
        let view = pantry([
            TestBuilders.pantryLine("potato", TestBuilders.grams(600), confirmedAt: t0),
            TestBuilders.pantryLine("cream cheese", TestBuilders.grams(200), confirmedAt: t0),
        ])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(restrictions: [TestBuilders.restriction(allergens: [.milk])]),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .nothingFeasible, "an ingredient with unresolved composition must not pass a milk restriction")
        XCTAssertTrue(proposal.options.isEmpty)
    }

    func testUndeclaredDietCompositionFailsClosed() throws {
        // A vegan eater and a candidate asserting no diet failures without
        // any evaluated diet evidence: the diet composition is unresolved,
        // and unevaluated is never satisfied (round 2, blocker 1).
        let stew = TestBuilders.revision("stew", lines: [
            TestBuilders.line("l1", "barley", TestBuilders.grams(100)),
            TestBuilders.line("l2", "beef", TestBuilders.grams(400)),
        ])
        let candidates = [(revision: stew, claims: RecipeClaims(allergensByIngredient: ["barley": [], "beef": []]))]
        let view = pantry([
            TestBuilders.pantryLine("barley", TestBuilders.grams(300), confirmedAt: t0),
            TestBuilders.pantryLine("beef", TestBuilders.grams(800), confirmedAt: t0),
        ])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(restrictions: [TestBuilders.restriction(diets: [.vegan])]),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .nothingFeasible, "an unevaluated diet composition must not pass a vegan exclusion")
        XCTAssertTrue(proposal.options.isEmpty)
    }

    func testOptionalGarnishNeedsResolvedComposition() throws {
        // Every included line reaches the plate, so an optional garnish is
        // not exempt from composition evidence (round 2, blocker 1: optional
        // ingredients are excluded from checks today).
        let dish = TestBuilders.revision("dish", lines: [
            TestBuilders.line("l1", "rice", TestBuilders.grams(200)),
            TestBuilders.line("l2", "mixed nuts", TestBuilders.grams(15), garnish: true),
        ])
        let candidates = [(revision: dish, claims: RecipeClaims(allergensByIngredient: ["rice": []]))]
        let view = pantry([
            TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0),
            TestBuilders.pantryLine("mixed nuts", TestBuilders.grams(100), confirmedAt: t0),
        ])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(restrictions: [TestBuilders.restriction(allergens: [.treeNuts])]),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .nothingFeasible, "a garnish with unresolved composition must not pass a tree-nut restriction")
        XCTAssertTrue(proposal.options.isEmpty)
    }

    func testEmptyRestrictionNeedsNoCompositionEvidence() throws {
        // No eater restricts anything: no composition check runs, so there
        // is nothing to fail closed and a candidate with no evidence can
        // still be proposed. This pins the bounded scope of the fail-closed
        // rule: every check that RUNS must resolve.
        let dish = TestBuilders.revision("dish", lines: [
            TestBuilders.line("l1", "rice", TestBuilders.grams(200)),
        ])
        let candidates = [(revision: dish, claims: RecipeClaims())]
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0)])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.options.count, 1, "no restriction, no composition check to resolve")
    }

    // MARK: Review round 2, blocker 2 — assumed staples are never sufficient

    func testAssumedStapleIsNeverClaimedReady() throws {
        // A rice dish fully in stock except the policy staple salt, which
        // has NO pantry line: the dish may still be proposed, but it must
        // not claim "all lines in stock", and its assumption must be named
        // and turned into a check prompt (SPEC 3.2, round 2, blocker 2).
        let friedRice = TestBuilders.revision("fried-rice", lines: [
            TestBuilders.line("l1", "rice", TestBuilders.grams(200)),
            TestBuilders.line("l2", "salt", TestBuilders.grams(5)),
        ])
        let candidates = [(revision: friedRice, claims: RecipeClaims())]
        let view = pantry(
            [TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0)],
            staples: ["salt"]
        )
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        let option = try XCTUnwrap(proposal.options.first, "the dish stays proposed with the assumption surfaced")
        XCTAssertFalse(
            option.reasons.contains(where: { $0.contains("all 2 required lines are in stock") }),
            "an assumed staple never backs a ready claim"
        )
        XCTAssertTrue(
            option.reasons.contains(where: { $0.contains("assumes salt") }),
            "the assumption is named, not hidden"
        )
        XCTAssertTrue(option.fit.checkNames.contains("salt"), "the staple becomes a check prompt, not a silent pass")
        XCTAssertEqual(option.fit.sufficientCount, 1, "only evidence-backed lines count as sufficient")
    }

    func testRestrictionsOfTwoEatersAreUnited() throws {
        // Eater 1 avoids peanuts, eater 2 avoids shellfish. A dish with
        // shellfish must be blocked even though eater 1 could eat it.
        let paella = TestBuilders.revision("paella", lines: [
            TestBuilders.line("l1", "shrimp", TestBuilders.grams(300)),
        ])
        let candidates = [(revision: paella, claims: RecipeClaims(allergensByIngredient: ["shrimp": [.shellfish]]))]
        let view = pantry([TestBuilders.pantryLine("shrimp", TestBuilders.grams(800), confirmedAt: t0)])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(restrictions: [
                TestBuilders.restriction(allergens: [.peanuts]),
                TestBuilders.restriction(allergens: [.shellfish]),
            ]),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .nothingFeasible)
    }

    func testCustomExclusionBlocksByCanonicalName() throws {
        let dish = TestBuilders.revision("dish", lines: [
            TestBuilders.line("l1", "coriander", TestBuilders.grams(10)),
            TestBuilders.line("l2", "rice", TestBuilders.grams(200)),
        ])
        let candidates = [(revision: dish, claims: RecipeClaims())]
        let view = pantry([
            TestBuilders.pantryLine("coriander", TestBuilders.grams(100), confirmedAt: t0),
            TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0),
        ])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(restrictions: [TestBuilders.restriction(custom: ["coriander"])]),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .nothingFeasible)
    }

    func testQuarantinedRevisionIsNeverProposed() throws {
        // Unknown rights means quarantine (SPEC 3.5).
        let unknownLicense = try! RecipeLicense(
            textRedistribution: .unknown,
            imageRedistribution: .unknown,
            modificationAllowed: .unknown,
            attributionRequired: false,
            cachingAllowed: .unknown,
            offlineUseAllowed: .unknown,
            evidence: "no rights evidence recorded"
        )
        let suspicious = TestBuilders.revision("suspicious", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(100))])
        let withUnknownRights = try! RecipeRevision(
            key: TestBuilders.recipeKey("suspicious"),
            title: "Mystery casserole",
            servingBasis: try! ServingBasis(servings: 2),
            ingredientLines: suspicious.ingredientLines,
            steps: suspicious.steps,
            source: RecipeSourceEvidence(origin: .catalog, attribution: nil, license: unknownLicense)
        )
        let candidates = [(revision: withUnknownRights, claims: RecipeClaims())]
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0)])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .nothingFeasible, "unknown rights is quarantine, not permission")
    }

    // MARK: Explainability

    func testOptionCarriesWhyItWasProposedAndWhatIsMissing() throws {
        let galette = TestBuilders.revision("galette", lines: [
            TestBuilders.line("l1", "flour", TestBuilders.grams(250)),
            TestBuilders.line("l2", "feta", TestBuilders.grams(150)),
            TestBuilders.line("l3", "eggs", TestBuilders.grams(120)),
        ])
        let candidates = [(revision: galette, claims: RecipeClaims())]
        let view = pantry([
            TestBuilders.pantryLine("flour", TestBuilders.grams(1000), confirmedAt: t0),
            TestBuilders.pantryLine("feta", TestBuilders.grams(100), confirmedAt: t0),
            TestBuilders.pantryLine("eggs", .unknown, confirmedAt: t0),
        ])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.options.count, 1)
        let option = try XCTUnwrap(proposal.options.first)
        XCTAssertFalse(option.reasons.isEmpty, "every option carries why it was proposed")
        XCTAssertTrue(option.reasons[0].contains("2 of 3"), "the reason states the real counts")

        // The missing lines carry the exact states: feta short 50 g, eggs unknown.
        let feta = try XCTUnwrap(option.missing.first(where: { $0.canonicalName == "feta" }))
        XCTAssertEqual(feta.kind, .short)
        XCTAssertEqual(feta.grams, 50)
        let eggs = try XCTUnwrap(option.missing.first(where: { $0.canonicalName == "eggs" }))
        XCTAssertEqual(eggs.kind, .unknownQuantity)
        XCTAssertNil(eggs.grams, "unknown is never turned into a number")

        // The shopping list has the same truth.
        let list = try XCTUnwrap(proposal.shoppingList)
        XCTAssertTrue(list.contains(where: { $0.canonicalName == "feta" && $0.grams == 50 }))
    }

    func testFitLineMatchesTheSpecShapes() throws {
        // Ready: "9 of 10 · 1 swap" only when nine lines are sufficient.
        let ready = try FitLine(requiredCount: 10, sufficientCount: 9, swapCount: 1, checkNames: [])
        XCTAssertEqual(ready.display, "9 of 10 · 1 swap")
        XCTAssertTrue(ready.isReady)

        // Not ready: "7 recorded · check eggs and oil". Never a percentage.
        let partial = try FitLine(requiredCount: 9, sufficientCount: 7, checkNames: ["eggs", "oil"])
        XCTAssertEqual(partial.display, "7 recorded · check eggs and oil")
        XCTAssertFalse(partial.isReady)
        XCTAssertFalse(partial.display.contains("%"))
    }

    func testFitLineRefusesInconsistentCounts() {
        XCTAssertThrowsError(try FitLine(requiredCount: 3, sufficientCount: 5, checkNames: []))
    }

    // MARK: Reservation only on selection

    func testAlternativesAreScoredAgainstTheSameStock() throws {
        // Two alternatives each want 200 g rice; 300 g exist. They are
        // alternatives until one is chosen: scoring one must not consume
        // stock from the other (review round 2, blocker 3 — the old
        // testPlanReservesStockAcrossOptions pinned the defect).
        let riceA = TestBuilders.revision("a-rice", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(200))])
        let riceB = TestBuilders.revision("b-rice", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(200))])
        let candidates = [
            (revision: riceB, claims: RecipeClaims()),
            (revision: riceA, claims: RecipeClaims()),
        ]
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(300), confirmedAt: t0)])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.options.count, 2)
        for option in proposal.options {
            XCTAssertTrue(option.fit.isReady, "\(option.recipeRevision) is scored against the full shelf, not the remainder after another alternative")
        }
    }

    func testPlanReservationCarriesThroughSelectionOnly() throws {
        // The plan-level contract, honestly this time: dinner 1's propose
        // reserves NOTHING (alternatives, not a sequence); when the caller
        // SELECTS an option it reserves via the engine, and only then does
        // dinner 2's propose see the remainder (review round 2, blocker 3).
        let riceA = TestBuilders.revision("a-rice", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(200))])
        let riceB = TestBuilders.revision("b-rice", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(200))])
        let candidates = [
            (revision: riceB, claims: RecipeClaims()),
            (revision: riceA, claims: RecipeClaims()),
        ]
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(300), confirmedAt: t0)])

        // Dinner 1: both alternatives ready on the same shelf.
        let dinner1 = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertTrue(dinner1.options.allSatisfy { $0.fit.isReady })

        // Selection: the caller reserves the chosen option's stock.
        var planLedger = StockLedger(pantry: view)
        _ = try FeasibilityEngine.evaluateAndReserve(
            revision: riceA,
            servings: 2,
            pantry: view,
            ledger: &planLedger
        )
        guard case .known(let remaining)? = planLedger.entry(for: "rice") else {
            return XCTFail("the selection must record the reserved remainder")
        }
        XCTAssertEqual(remaining.grams, 100, accuracy: 0.001, "300 - 200 reserved for the chosen dinner")

        // Dinner 2 now sees the remainder — through the caller's ledger,
        // never through dinner 1's propose.
        let dinner2 = try DinnerDecisionService.propose(
            candidates: [(revision: riceB, claims: RecipeClaims())],
            context: context(),
            pantry: view,
            reservations: planLedger,
            now: t0
        )
        let option = try XCTUnwrap(dinner2.options.first)
        XCTAssertFalse(option.fit.isReady, "dinner 2 sees what the selected dinner reserved")
    }

    // MARK: Tonight states

    func testEmptyPantryIsUnknownKitchen() throws {
        let revision = TestBuilders.revision("a", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(100))])
        let view = pantry([])
        let proposal = try DinnerDecisionService.propose(
            candidates: [(revision: revision, claims: RecipeClaims())],
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .unknownKitchen)
        XCTAssertTrue(proposal.options.isEmpty)
        XCTAssertNil(proposal.shoppingList)
    }

    func testSparseKitchenWithFewLines() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "rice", TestBuilders.grams(100)),
            TestBuilders.line("l2", "eggs", TestBuilders.grams(120)),
        ])
        let view = pantry([
            TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0),
            TestBuilders.pantryLine("eggs", TestBuilders.grams(600), confirmedAt: t0),
        ])
        let proposal = try DinnerDecisionService.propose(
            candidates: [(revision: revision, claims: RecipeClaims())],
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.state, .sparseKitchen)
        XCTAssertTrue(proposal.options.allSatisfy { $0.fit.isReady }, "sparse but honest: this pick really is ready")
    }

    func testMidCookResumeLeadsTonight() throws {
        let card = try ResumeCard(sessionID: "sess-1", recipeTitle: "Test a", stepIndex: 1, stepCount: 3, dueTimerLabels: [])
        let revision = TestBuilders.revision("a", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(100))])
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0)])
        let proposal = try DinnerDecisionService.propose(
            candidates: [(revision: revision, claims: RecipeClaims())],
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            resume: card,
            now: t0
        )
        XCTAssertEqual(proposal.state, .midCookResume)
        XCTAssertEqual(proposal.resume?.sessionID, "sess-1")
        XCTAssertTrue(proposal.options.isEmpty, "the resume card leads; options wait")
    }

    // MARK: Repeated rejection

    func testThirdRejectionOffersConstraintChoice() throws {
        var session = TonightSession()
        let a = TestBuilders.recipeKey("a")
        let b = TestBuilders.recipeKey("b")
        let c = TestBuilders.recipeKey("c")
        session.reject(revision: a)
        session.reject(revision: b)
        XCTAssertFalse(session.shouldOfferConstraintChoice)
        session.reject(revision: c)
        XCTAssertTrue(session.shouldOfferConstraintChoice, "after the third 'Something else', offer a constraint choice")

        let revision = TestBuilders.revision("d", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(100))])
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0)])
        let proposal = try DinnerDecisionService.propose(
            candidates: [(revision: revision, claims: RecipeClaims())],
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            rejectedRevisions: session.rejectedRevisions,
            rejectionCount: session.rejectionCount,
            now: t0
        )
        XCTAssertEqual(proposal.state, .repeatedRejection)
        XCTAssertEqual(proposal.constraintChoices, ConstraintChoice.allCases)
        XCTAssertTrue(proposal.options.isEmpty)
    }

    func testRejectedRevisionsAreNotOfferedAgainButNothingIsRecordedAsTaste() throws {
        var session = TonightSession()
        session.reject(revision: TestBuilders.recipeKey("a"))
        let rejectedA = TestBuilders.revision("a", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(100))])
        let freshB = TestBuilders.revision("b", lines: [TestBuilders.line("l1", "eggs", TestBuilders.grams(100))])
        let view = pantry([
            TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0),
            TestBuilders.pantryLine("eggs", TestBuilders.grams(600), confirmedAt: t0),
        ])
        let proposal = try DinnerDecisionService.propose(
            candidates: [
                (revision: rejectedA, claims: RecipeClaims()),
                (revision: freshB, claims: RecipeClaims()),
            ],
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            rejectedRevisions: session.rejectedRevisions,
            rejectionCount: session.rejectionCount,
            now: t0
        )
        XCTAssertEqual(proposal.options.map(\.recipeRevision), [TestBuilders.recipeKey("b")],
                       "the just-rejected option is not offered again")
    }

    // MARK: Determinism

    func testSameInputsProduceIdenticalProposals() throws {
        // Two candidates with symmetric feasibility: the key breaks the tie.
        let a = TestBuilders.revision("alpha", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(100))])
        let b = TestBuilders.revision("beta", lines: [TestBuilders.line("l1", "eggs", TestBuilders.grams(100))])
        let candidates = [
            (revision: b, claims: RecipeClaims()),
            (revision: a, claims: RecipeClaims()),
        ]
        let view = pantry([
            TestBuilders.pantryLine("rice", TestBuilders.grams(900), confirmedAt: t0),
            TestBuilders.pantryLine("eggs", TestBuilders.grams(600), confirmedAt: t0),
        ])
        func make() throws -> TonightProposal {
            try DinnerDecisionService.propose(
                candidates: candidates,
                context: context(),
                pantry: view,
                reservations: StockLedger(pantry: view),
                now: t0
            )
        }
        let first = try make()
        let second = try make()
        XCTAssertEqual(first, second)
        let firstBytes = try FLJSON.canonicalData(first)
        let secondBytes = try FLJSON.canonicalData(second)
        XCTAssertEqual(firstBytes, secondBytes, "pure decision: same inputs, same canonical bytes")
    }

    func testMaxFourOptionsAreProposed() throws {
        let candidates: [(revision: RecipeRevision, claims: RecipeClaims)] = (1...6).map { index in
            (revision: TestBuilders.revision("r\(index)", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(100))]), claims: RecipeClaims())
        }
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(10_000), confirmedAt: t0)])
        let proposal = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context(),
            pantry: view,
            reservations: StockLedger(pantry: view),
            now: t0
        )
        XCTAssertEqual(proposal.options.count, DinnerDecisionService.maxOptions)
        XCTAssertEqual(proposal.state, .normal)
    }
}
