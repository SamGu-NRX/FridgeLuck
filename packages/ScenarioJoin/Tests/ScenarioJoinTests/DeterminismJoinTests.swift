import Testing
import Foundation
import FLDomain
import FLFlowCore
import FLInventoryCore
import FLRecipeCore
@testable import FLScenarioKit

// S6 — replayability: the same scenario, seeded and deterministic, produces
// the same evidence twice. Every PR-proof trace must be reproducible byte
// for byte on a fresh run (PLAN: replayable evidence).

@Suite("S6 · Determinism and replay")
struct DeterminismJoinTests {
    // A two-day miniature of the S1 arc, built from the same fixture
    // builders: purchase → correct → propose → reject → pick. Returns the
    // canonical trace so two fresh runs can be compared byte for byte.
    private func runMiniWeek() throws -> Data {
        var trace = ScenarioTrace()
        let world = try HouseholdWorld()
        let hh = world.householdID
        var clock = WeekClock(startingAt: Week.start)

        try world.ledger.apply(Fixtures.purchase(
            "ev-m-tomatoes", "tomatoes", grams: 600,
            household: hh, command: "cmd-m-1", at: clock.now, source: .receipt
        ))
        clock.advance(days: 1)
        clock.advance(hours: 17)
        try world.ledger.apply(Fixtures.correction(
            "ev-m-correct", "tomatoes", grams: 540,
            household: hh, command: "cmd-m-2", at: clock.now,
            supersedes: "ev-m-tomatoes"
        ))

        let soup = Fixtures.revision("r-soup", title: "Tomato soup", lines: [
            Fixtures.line("l1", "tomatoes", 500),
            Fixtures.line("l2", "whole milk", 100),
        ])
        let stock = try world.stock()
        let report = try FLPantryFeasibility.evaluate(
            recipe: soup,
            stock: stock,
            restriction: Fixtures.restriction(allergens: [], diets: []),
            now: clock.now
        )
        trace.record("fit", "soup outcome: \(report.outcome == .complete ? "complete" : "incomplete")")
        trace.record("tomatoes", "\(try world.stock().first { $0.ingredient.canonicalName == "tomatoes" }?.totalKnownRemainingGrams ?? -1)g after correction")
        return try trace.canonicalJSON()
    }

    @Test("Two fresh runs of the same scenario produce byte-identical evidence")
    func miniWeekReplay() throws {
        let first = try runMiniWeek()
        let second = try runMiniWeek()
        #expect(first == second, "same scenario, same bytes")
    }

    @Test("Tonight's proposal is a pure function of its inputs: identical inputs, identical canonical form")
    func proposalPurity() throws {
        var clock = WeekClock(startingAt: Week.day(2, hour: 17, minute: 30))
        let world = try HouseholdWorld()
        let hh = world.householdID
        try world.ledger.applyBatch([
            Fixtures.purchase("ev-pp-tomatoes", "tomatoes", grams: 540, household: hh, command: "cmd-pp", at: clock.now, source: .receipt),
            Fixtures.purchase("ev-pp-milk", "whole milk", grams: 500, household: hh, command: "cmd-pp", at: clock.now, source: .receipt),
        ])
        let pantry = try world.pantryView(now: clock.now)
        let context = try MealContext(
            eaters: [Eater(name: "Aiko", restriction: Fixtures.restriction(allergens: [.peanuts], diets: []))],
            servings: 2
        )
        let candidates = [
            (revision: Fixtures.revision("r-soup", title: "Tomato soup", lines: [
                Fixtures.line("l1", "tomatoes", 500),
                Fixtures.line("l2", "whole milk", 100),
            ]), claims: RecipeClaims(allergensByIngredient: [:], failingDietTags: [], estimatedSeconds: 900)),
            (revision: Fixtures.revision("r-curry", title: "Chickpea curry", lines: [
                Fixtures.line("l1", "chickpeas", 400),
            ]), claims: RecipeClaims(allergensByIngredient: [:], failingDietTags: [], estimatedSeconds: 600)),
        ]

        let a = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context,
            pantry: pantry,
            reservations: StockLedger(pantry: pantry),
            now: clock.now
        )
        clock.advance(minutes: 0) // no time passes; only identity of inputs matters
        let b = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context,
            pantry: pantry,
            reservations: StockLedger(pantry: pantry),
            now: clock.now
        )
        let aBytes = try FLJSON.canonicalData(a)
        let bBytes = try FLJSON.canonicalData(b)
        #expect(aBytes == bBytes, "same inputs → same proposal bytes")
        #expect(a.options.map(\.title) == b.options.map(\.title))
        #expect(a.options.map(\.title).contains("Tomato soup"))
    }

    @Test("The scenario clock cannot run backwards; advances are strictly ordered")
    func clockMonotonicity() {
        var clock = WeekClock(startingAt: Week.start)
        let stamps = (0..<20).map { i -> TimeInterval in
            clock.advance(minutes: Double(i))
            return clock.now.timeIntervalSince1970
        }
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 < $1 }, "every advance moves forward")
        #expect(clock.now > Week.start)
    }
}
