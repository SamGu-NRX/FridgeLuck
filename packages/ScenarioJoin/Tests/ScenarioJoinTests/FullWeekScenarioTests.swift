import Testing
import Foundation
import FLDomain
import FLFlowCore
import FLAssistantCore
import FLInventoryCore
import FLRecipeCore
import FLCommunityCore
@testable import FLScenarioKit

// S1 — the operator-specified week-long household arc, end to end on Linux:
// scan → reconcile → pick dinner → reject twice → cook with a swap → kill
// mid-cook → resume → complete → share to the table → run the challenge —
// asserting the cross-package contracts at every step (SPEC.md §3, PLAN.md
// suite A). Deterministic, offline, synthetic data only.

/// The device-side executor: a timer exists on the phone ONLY after the
/// authority executes the approved proposal (SPEC 3.6).
private actor DeviceTimerExecutor: ActionExecutor {
    private(set) var createdTimers: [(label: String, seconds: Int)] = []

    func apply(_ payload: ActionPayload, proposal: ActionProposal) async throws {
        guard case let .timerCreate(label, seconds) = payload else {
            return
        }
        createdTimers.append((label: label, seconds: seconds))
    }
}

@Suite("S1 · Full week household arc")
struct FullWeekScenarioTests {
    // The household: two eaters. Aiko is allergic to peanuts; Ben excludes
    // meat. The union restriction is what Tonight filters and what every
    // swap must recheck (SPEC 3.1).
    private let eaters: [(name: String, allergens: Set<Allergen>, diets: Set<DietExclusion>)] = [
        ("Aiko", [.peanuts], []),
        ("Ben", [], [.vegetarian]),
    ]

    private var mealContext: MealContext {
        let contextEaters = eaters.map { eater in
            Eater(name: eater.name, restriction: Fixtures.restriction(allergens: eater.allergens, diets: eater.diets))
        }
        return try! MealContext(eaters: contextEaters, servings: 2)
    }

    private var unionRestriction: Restriction {
        try! mealContext.unionRestriction
    }

    // Fixture recipes. Only FLDomain-validated values; no I/O, no randomness.
    //   R-flourcake — stale-evidence probe (flour seeded three weeks back).
    //   R-noodles   — peanut recipe: must be filtered before ranking.
    //   R-curry     — cookable; rejected Tuesday, cooked Wednesday.
    //   R-soup      — cookable; rejected Tuesday, cooked Friday (spoiled).
    //   R-stir      — Tuesday's pick: sesame oil short, swapped to olive oil.
    private func menu() -> [RecipeRevision] {
        [
            Fixtures.revision("r-flourcake", title: "Flour pancakes", lines: [
                Fixtures.line("l1", "all-purpose flour", 200),
                Fixtures.line("l2", "whole milk", 300),
            ]),
            Fixtures.revision("r-noodles", title: "Peanut noodles", lines: [
                Fixtures.line("l1", "peanuts", 80),
                Fixtures.line("l2", "rice noodles", 250),
            ]),
            Fixtures.revision("r-curry", title: "Chickpea curry", lines: [
                Fixtures.line("l1", "chickpeas", 400),
                Fixtures.line("l2", "coconut milk", 200),
                Fixtures.line("l3", "lemon", 30),
            ]),
            Fixtures.revision("r-soup", title: "Tomato soup", lines: [
                Fixtures.line("l1", "tomatoes", 500),
                Fixtures.line("l2", "whole milk", 100),
            ]),
            Fixtures.revision("r-stir", title: "Vegetable stir-fry", lines: [
                Fixtures.line("l1", "broccoli", 300),
                Fixtures.line("l2", "sesame oil", 20),
                Fixtures.line("l3", "lemon", 30),
            ], steps: [
                Fixtures.step("s1", seconds: 300),
                Fixtures.step("s2", seconds: 240),
                Fixtures.step("s3", seconds: 120),
            ]),
        ]
    }

    private func claims(for revision: RecipeRevision) -> RecipeClaims {
        // Declared claims (synthetic, compound ingredients already resolved —
        // the port's contract). Everything here is catalog data, not evidence.
        let declaredAllergens: [String: Set<Allergen>] = [
            "peanuts": [.peanuts],
            "sesame oil": [.sesame],
        ]
        var perIngredient: [String: Set<Allergen>] = [:]
        for line in revision.ingredientLines {
            perIngredient[line.ingredient.canonicalName] = declaredAllergens[line.ingredient.canonicalName] ?? []
        }
        return RecipeClaims(allergensByIngredient: perIngredient, failingDietTags: [], estimatedSeconds: revision.ingredientLines.count * 300)
    }

    @Test("Full arc: scan → reconcile → pick (reject ×2) → swap → kill → resume → complete → share → challenge")
    func fullWeekArc() async throws {
        var trace = ScenarioTrace()
        var clock = WeekClock(startingAt: Week.start)
        let world = try HouseholdWorld()
        let hh = world.householdID
        let menu = menu()
        let stir = menu[4]
        let curry = menu[2]
        let soup = menu[3]
        let context = mealContext
        let restriction = unionRestriction

        // ── Seed (2026-09-19): flour bought 16 days before the week starts —
        // the staleness probe that goes stale mid-scenario. ──
        let seedClock = WeekClock(startingAt: Week.day(-16, hour: 10))
        try world.ledger.apply(Fixtures.purchase(
            "ev-flour", "all-purpose flour", grams: 1000,
            household: hh, command: "cmd-seed-flour", at: seedClock.now,
            source: .receipt
        ))
        trace.record("seed", "all-purpose flour purchased 1000g; by Tuesday it is past the 14-day reconfirm window")

        // ── Day 1 (Mon): a shelf scan, then the week's groceries. ──
        #expect(clock.now == Week.day(1, hour: 0), "the clock starts at the week's first midnight")

        // Scan: observation, never addition; no amount read → unknown.
        try world.ledger.apply(Fixtures.observation(
            "ev-scan-eggs", "eggs", grams: nil,
            household: hh, command: "cmd-scan-eggs", at: clock.now
        ))
        let eggsStock = try world.stock().first { $0.ingredient.canonicalName == "eggs" }
        #expect(eggsStock != nil)
        #expect(eggsStock?.totalKnownRemainingGrams == nil, "a scan without an amount stays unknown — never zero, never a guess")
        trace.record("d1-scan", "eggs observed without amount → unknown evidence")

        // The grocery command: one atomic batch, one command ID.
        let groceryCommand = "cmd-groceries-w41"
        try world.ledger.applyBatch([
            Fixtures.purchase("ev-p-broccoli", "broccoli", grams: 400, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
            Fixtures.purchase("ev-p-chickpeas", "chickpeas", grams: 400, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
            Fixtures.purchase("ev-p-coconut", "coconut milk", grams: 400, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
            Fixtures.purchase("ev-p-tomatoes", "tomatoes", grams: 600, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
            Fixtures.purchase("ev-p-lemon", "lemon", grams: 150, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
            Fixtures.purchase("ev-p-oliveoil", "olive oil", grams: 250, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
            Fixtures.purchase("ev-p-milk", "whole milk", grams: 500, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
            Fixtures.purchase("ev-p-yogurt", "yogurt", grams: 300, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
        ])
        // Idempotent retry of the SAME command: no change, no duplicates.
        let retry = try world.ledger.applyBatch([
            Fixtures.purchase("ev-p-broccoli", "broccoli", grams: 400, household: hh, command: groceryCommand, at: clock.now, source: .receipt),
        ])
        #expect(retry == .alreadyApplied)
        #expect(try world.stock().first { $0.ingredient.canonicalName == "broccoli" }?.totalKnownRemainingGrams == 400)
        trace.record("d1-receipt", "8-line grocery command applied atomically; retry → .alreadyApplied")

        // ── Day 1 reconcile: the drawer check corrects one line and retracts
        // a mistaken entry. Corrections supersede; they never erase. ──
        clock.advance(minutes: 15)
        try world.ledger.apply(Fixtures.correction(
            "ev-c-tomatoes", "tomatoes", grams: 540,
            household: hh, command: "cmd-correct-tomatoes", at: clock.now,
            supersedes: "ev-p-tomatoes"
        ))
        try world.ledger.apply(Fixtures.purchase(
            "ev-p-yogurt2", "yogurt", grams: 300,
            household: hh, command: "cmd-mistaken-yogurt", at: clock.now, source: .manual
        ))
        try world.ledger.apply(try! FLStockEvent(
            id: "ev-r-yogurt2",
            commandID: "cmd-retract-yogurt2",
            householdID: hh,
            kind: .correction,
            ingredient: Fixtures.ingredient("yogurt"),
            quantity: .unknown,
            source: .manual,
            timestamp: clock.now,
            supersedes: FLStockCorrection(priorEventID: StockEventID("ev-p-yogurt2"), mode: .retracts)
        ))
        let d1Stock = try world.stock()
        #expect(d1Stock.first { $0.ingredient.canonicalName == "tomatoes" }?.totalKnownRemainingGrams == 540, "correction supersedes the purchase, never erases it")
        #expect(d1Stock.first { $0.ingredient.canonicalName == "yogurt" }?.totalKnownRemainingGrams == 300, "the retraction removes the mistaken duplicate; the legitimate 300g grocery lot remains")
        let d1Events = try world.ledger.events(householdID: hh)
        #expect(d1Events.count == 13, "full history intact, retractions included: \(d1Events.count) events (superseded ones are never deleted)")
        trace.record("d1-reconcile", "tomatoes corrected 600→540; mistaken yogurt retracted; history preserved")

        // ── Day 2 (Tue 17:30): Tonight — restrict, reject twice, swap. ──
        clock.advance(to: Week.day(2, hour: 17, minute: 30))
        #expect(clock.now == Week.day(2, hour: 17, minute: 30))

        // 1) Restrictions are filtered BEFORE ranking (SPEC 3.3): the peanut
        //    recipe never appears as an option the household could decline.
        let pantryNow = try world.pantryView(now: clock.now)
        let candidates = menu.map { (revision: $0, claims: claims(for: $0)) }
        let first = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context,
            pantry: pantryNow,
            reservations: StockLedger(pantry: pantryNow),
            now: clock.now
        )
        #expect(!first.options.isEmpty)
        #expect(first.options.allSatisfy { $0.title != "Peanut noodles" }, "the peanut recipe is filtered before ranking")
        #expect(first.state == .normal)
        trace.record("d2-restrict", "Peanut noodles filtered before ranking; \(first.options.count) options proposed")

        // 2) The stale probe through BOTH engines: flow's proposal marks the
        //    flour line needsReconfirming; FLRecipeCore's audit engine agrees.
        let pancakeOption = first.options.first { $0.title == "Flour pancakes" }
        let flowSaysStale = pancakeOption?.missing.contains { $0.canonicalName == "all-purpose flour" && $0.kind == .needsReconfirming }
        #expect(flowSaysStale == true, "flow's engine calls 17-day-old flour stale")
        if let flowSaysStale, flowSaysStale {
            trace.record("d2-stale-flow", "flow fit line: \(pancakeOption?.fit.display ?? "?")")
        }
        let pantryReport = try FLPantryFeasibility.evaluate(
            recipe: menu[0],
            stock: try world.stock(),
            restriction: restriction,
            now: clock.now
        )
        #expect(pantryReport.outcome != .complete, "stale flour cannot read as fully cookable")
        let flourLine = try #require(pantryReport.lines.first { $0.ingredient.canonicalName == "all-purpose flour" })
        #expect(flourLine.state == .needsReconfirming, "FLRecipeCore agrees: same evidence, same staleness")
        trace.record("d2-stale", "flour needsReconfirming in both engines (17d > 14d window)")

        // 3) Reject twice within the session; rejected keys never reappear
        //    while the session holds (SPEC 2: rejections are not dislikes).
        var session = TonightSession()
        session.reject(revision: curry.key)
        session.reject(revision: soup.key)
        #expect(session.rejectionCount == 2, "two rejections, under the three-strikes threshold")
        let second = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context,
            pantry: pantryNow,
            reservations: StockLedger(pantry: pantryNow),
            rejectedRevisions: session.rejectedRevisions,
            rejectionCount: session.rejectionCount,
            now: clock.now
        )
        let secondTitles = second.options.map(\.title)
        #expect(!secondTitles.contains("Chickpea curry"), "a twice-rejected dinner does not reappear without new evidence")
        #expect(!secondTitles.contains("Tomato soup"))
        #expect(secondTitles.contains("Vegetable stir-fry"))
        #expect(second.options.first?.title == "Vegetable stir-fry", "the untouched option with the most sufficient lines ranks first")
        trace.record("d2-reject", "rejected curry + soup; stir-fry now ranks first: \(secondTitles.joined(separator: " | "))")

        // 4) The short line and the swap. Sesame oil is not on the shelf at
        //    all; the accepted substitution is olive oil (250g from the
        //    receipt). The pantry engine models the swap; the SPEC 3.1 gate
        //    rechecks every eater before it may be accepted.
        let stirReportNoSwap = try FLPantryFeasibility.evaluate(
            recipe: stir,
            stock: try world.stock(),
            restriction: restriction,
            now: clock.now
        )
        #expect(stirReportNoSwap.missingIngredients.map(\.canonicalName).contains("sesame oil"))
        let swap = try FLPantryFeasibility.FLAcceptedSwap(
            replacesGroupKey: FLStockFold.groupKey(for: Fixtures.ingredient("sesame oil")),
            substitute: Fixtures.ingredient("olive oil"),
            gramsFactor: 1.0
        )
        let stirReportSwapped = try FLPantryFeasibility.evaluate(
            recipe: stir,
            stock: try world.stock(),
            restriction: restriction,
            swaps: [swap],
            now: clock.now
        )
        #expect(stirReportSwapped.outcome == .complete, "with the swap the bill is complete")
        let gate = SwapGate.recheck(
            substitute: Fixtures.ingredient("olive oil"),
            substituteAllergens: [],
            eaterAllergens: eaters.map { (name: $0.name, allergens: $0.allergens) }
        )
        #expect(gate.allowed, "\(gate.explanation)")
        trace.record("d2-swap", "sesame oil missing → olive-oil swap accepted after the SPEC 3.1 recheck; bill complete")

        // ── Day 2 (17:55): cook with the swap — flow's session takes over. ──
        clock.advance(minutes: 25)
        #expect(clock.now == Week.day(2, hour: 17, minute: 55))
        let startedAt = clock.now
        let cookSessionID = "cook-2026-w41-stir"
        var cook = try CookSession.start(sessionID: cookSessionID, revision: stir, now: clock.now)
        #expect(cook.stage == .cooking)
        trace.record("d2-cook-start", "session \(cookSessionID) started at 17:55 over \(stir.steps.count) steps")

        // The assistant earns a timer the device may only set after approval.
        let snapshot = try await AssistantContextBuilder(
            stateSource: WorldStateSource(
                lines: try world.assistantLines(),
                recipe: stir.key,
                step: cook.checkpoint.stepIndex
            ),
            revisionClock: world.revisionClock
        ).buildSnapshot(sessionID: cookSessionID, now: clock.now)
        let authority = AssistantAuthority(ledger: world.receiptLedger)
        let timerPayload = ActionPayload.timerCreate(label: "Stir-fry the broccoli", seconds: 240)
        let timerProposal = try await authority.propose(
            from: try ToolInvocation(tool: .proposeTimer, payload: timerPayload),
            against: snapshot,
            now: clock.now
        )
        let pending = try await world.receiptLedger.latestReceipt(proposalID: timerProposal.id)
        #expect(pending?.state == .pendingApproval, "the arrival receipt exists before any decision")
        let timerApproval = try ActionApproval(
            proposalID: timerProposal.id,
            payloadHash: try FLPayloadHashing.payloadHash(timerPayload),
            snapshotRevision: snapshot.revision,
            approvedAt: clock.now
        )
        let deviceTimers = DeviceTimerExecutor()
        _ = try await authority.approve(timerApproval, executor: deviceTimers, now: clock.now)
        #expect(await deviceTimers.createdTimers.count == 1, "the device created exactly the approved timer")
        cook = try cook.addTimer(
            id: "timer-1",
            label: await deviceTimers.createdTimers[0].label,
            deadline: clock.now.addingTimeInterval(240),
            now: clock.now
        )
        trace.record("d2-timer", "timer proposed → approved → executed → device timer armed (deadline 17:59)")

        // Step 1 completes; the process is then killed at 18:00.
        clock.advance(minutes: 5)
        cook = try cook.completeStep(now: clock.now)
        #expect(cook.checkpoint.stepIndex == 1)
        let checkpoint = cook.checkpoint
        #expect(checkpoint.completedStepIDs == ["s1"], "the checkpoint holds completed work, in order")
        #expect(checkpoint.timers.count == 1)
        #expect(checkpoint.timers[0].acknowledged == false)
        trace.record("d2-kill", "process killed at 18:00; only the checkpoint survives (step 2/4, 1 timer)")

        // ── RESUME at 18:10: recovery decides from the bare checkpoint. ──
        clock.advance(minutes: 10)
        #expect(clock.now == Week.day(2, hour: 18, minute: 10))
        let stepIDs = stir.steps.map(\.stepID)
        let decision = try CookSession.recover(checkpoint: checkpoint, stepIDs: stepIDs, now: clock.now)
        guard case let .resume(resumedIndex, expiredTimerIDs) = decision else {
            Issue.record("expected .resume, got \(decision)")
            return
        }
        #expect(resumedIndex == 1, "resume lands on the last completed step")
        #expect(expiredTimerIDs == ["timer-1"], "the timer expired while the app was dead — surfaced, never acknowledged implicitly")
        cook = try CookSession.reinstate(checkpoint: checkpoint, stepIDs: stepIDs, now: clock.now)
        cook = try cook.acknowledgeTimer(id: "timer-1", now: clock.now)
        trace.record("d2-resume", "recovered at step 2 of \(stepIDs.count); expired timer acknowledged")

        // The remaining steps finish.
        clock.advance(minutes: 4)
        cook = try cook.completeStep(now: clock.now)
        clock.advance(minutes: 3)
        cook = try cook.completeStep(now: clock.now)
        #expect(cook.stage == .finished)
        trace.record("d2-finish", "all steps complete at 18:17; stage .finished")

        // ── Complete: the meal-log hand-off. FLFlowCore's makeHandoff builds
        // the base record; the join attaches the accepted swap (the
        // makeHandoff gap is a recorded join contract request) and commits
        // through flow's own atomic path. ──
        let baseCook = try MealLog.makeHandoff(
            session: cook,
            cookID: "cook-w41-stir",
            eventID: "evt-w41-stir",
            servings: 2,
            rating: 5,
            wouldRepeat: true,
            note: nil,
            startedAt: startedAt
        ).cook
        let finalCook = try Cook(
            id: baseCook.id,
            recipeRevision: baseCook.recipeRevision,
            servings: baseCook.servings,
            substitutions: [
                try CookSubstitution(
                    from: Fixtures.ingredient("sesame oil"),
                    to: Fixtures.ingredient("olive oil"),
                    necessity: .necessary
                )
            ],
            rating: baseCook.rating,
            note: baseCook.note,
            startedAt: baseCook.startedAt,
            completedAt: baseCook.completedAt
        )
        try MealLog.commit(
            MealLog.Handoff(
                cook: finalCook,
                event: PreferenceEvent(
                    id: "evt-w41-stir",
                    kind: .cookCompleted,
                    timestamp: finalCook.completedAt,
                    recipeRevision: finalCook.recipeRevision,
                    source: .appObserved,
                    rating: 5,
                    wouldRepeat: true,
                    note: nil
                )
            ),
            db: world.db
        )
        let logged = try world.loggedCooks()
        #expect(logged.count == 1)
        #expect(logged[0].id == "cook-w41-stir")
        #expect(logged[0].substitutions.count == 1, "the swap survived into the durable cook record")
        trace.record("d2-meallog", "meal-log committed atomically: cook + preference event, swap attached")

        // Post-commit side effects: FIFO consumption booked to the cook.
        _ = try world.ledger.applyBatch([
            Fixtures.consumption("ev-x-broccoli", "broccoli", grams: 300, household: hh, command: "cmd-cook-w41-stir", at: cook.checkpoint.updatedAt, cookID: finalCook.id),
            Fixtures.consumption("ev-x-oliveoil", "olive oil", grams: 20, household: hh, command: "cmd-cook-w41-stir", at: cook.checkpoint.updatedAt, cookID: finalCook.id),
            Fixtures.consumption("ev-x-lemon", "lemon", grams: 30, household: hh, command: "cmd-cook-w41-stir", at: cook.checkpoint.updatedAt, cookID: finalCook.id),
        ])
        let afterCook = try world.stock()
        #expect(afterCook.first { $0.ingredient.canonicalName == "broccoli" }?.totalKnownRemainingGrams == 100)
        #expect(afterCook.first { $0.ingredient.canonicalName == "olive oil" }?.totalKnownRemainingGrams == 230)
        trace.record("d2-consume", "FIFO consumption booked to the cook; broccoli 100g and olive oil 230g remain")

        // The cooked remainder re-enters the pantry as a leftover lot.
        _ = try world.ledger.apply(Fixtures.purchase(
            "ev-p-leftover-broccoli", "broccoli", grams: 80,
            household: hh, command: "cmd-leftover-w41-stir", at: clock.now,
            source: .leftover, cookID: finalCook.id
        ))
        #expect(try world.stock().first { $0.ingredient.canonicalName == "broccoli" }?.lots.count == 2, "a leftover is a new FIFO lot, not an edit of the old one")
        trace.record("d2-leftover", "80g cooked broccoli re-entered as a leftover lot")

        // ── Share to the table (Tuesday evening). ──
        clock.advance(hours: 1)
        let day2 = Week.dayString(for: clock.now)
        let shared = try SharedCook(cook: finalCook, revision: stir, completedOn: day2)
        #expect(shared.servings == 2)
        #expect(shared.rating == 5)
        #expect(shared.swaps.count == 1)
        #expect(shared.swaps[0].to.canonicalName == "olive oil")
        #expect(shared.swaps[0].necessity == .necessary)
        #expect(shared.completedOn == "2026-10-06", "the share carries the day, never the instant (SPEC 3.4)")
        trace.record("d2-share", "SharedCook built for \(day2) with 1 recorded swap")

        // ── Day 3 (Wed): the previously-rejected curry cooks fine on a new
        // day — a rejection is a decision, not a grudge. ──
        clock.advance(to: Week.day(3, hour: 18, minute: 30))
        #expect(clock.now == Week.day(3, hour: 18, minute: 30))
        let freshPantry = try world.pantryView(now: clock.now)
        let fresh = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context,
            pantry: freshPantry,
            reservations: StockLedger(pantry: freshPantry),
            now: clock.now
        )
        #expect(fresh.options.map(\.title).contains("Chickpea curry"), "a fresh session may offer it again")
        var curryCook = try CookSession.start(sessionID: "cook-2026-w41-curry", revision: curry, now: clock.now)
        for _ in 0..<curry.steps.count {
            clock.advance(minutes: 4)
            curryCook = try curryCook.completeStep(now: clock.now)
        }
        try MealLog.commit(
            try MealLog.makeHandoff(
                session: curryCook,
                cookID: "cook-w41-curry",
                eventID: "evt-w41-curry",
                servings: 2,
                rating: 4,
                wouldRepeat: true,
                note: nil,
                startedAt: clock.now
            ),
            db: world.db
        )
        _ = try world.ledger.applyBatch([
            Fixtures.consumption("ev-x-chickpeas", "chickpeas", grams: 400, household: hh, command: "cmd-cook-w41-curry", at: curryCook.checkpoint.updatedAt, cookID: "cook-w41-curry"),
            Fixtures.consumption("ev-x-coconut", "coconut milk", grams: 200, household: hh, command: "cmd-cook-w41-curry", at: curryCook.checkpoint.updatedAt, cookID: "cook-w41-curry"),
            Fixtures.consumption("ev-x-lemon2", "lemon", grams: 30, household: hh, command: "cmd-cook-w41-curry", at: curryCook.checkpoint.updatedAt, cookID: "cook-w41-curry"),
        ])
        trace.record("d3-cook", "curry cooked and logged (rating 4); lemon down to 90g")

        // ── Day 5 (Fri 10:00): the tomatoes go off — waste is truth, not shame. ──
        clock.advance(to: Week.day(5, hour: 10))
        try world.ledger.apply(Fixtures.spoilage(
            "ev-s-tomatoes", "tomatoes", grams: 540,
            household: hh, command: "cmd-spoil-tomatoes", at: clock.now
        ))
        let fridayPantry = try world.pantryView(now: clock.now)
        let friday = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context,
            pantry: fridayPantry,
            reservations: StockLedger(pantry: fridayPantry),
            now: clock.now
        )
        // The soup may still surface (cookable-with-shopping is a legitimate
        // tier), but after the spoilage it must name its missing tomatoes —
        // it never claims the stock is still there.
        let soupOption = friday.options.first { $0.title == "Tomato soup" }
        #expect(soupOption == nil || soupOption?.missing.contains { $0.canonicalName == "tomatoes" } == true,
            "after the spoilage the soup never claims the tomatoes are in stock")
        trace.record("d5-tonight", "tomatoes spoiled: the soup, if surfaced, names them missing — no overclaim")

        // ── Day 7 (Sun 17:00): the challenge, derived from cook records only. ──
        clock.advance(to: Week.day(7, hour: 17))
        #expect(clock.now == Week.day(7, hour: 17))
        let definition = try ChallengeDefinition(
            id: "chal-lemon-week",
            title: "Cook two lemon recipes this week",
            goal: try ChallengeGoal(kind: .cookDistinctRecipes, targetCount: 2),
            requiredIngredientNames: ["lemon"],
            startsAt: Week.day(1, hour: 0),
            endsAt: Week.day(7, hour: 23, minute: 59)
        )
        let enrollment = try ChallengeEnrollment.join(definition: definition, at: Week.day(1, hour: 12), existing: nil)
        let cooks = try world.loggedCooks()
        #expect(cooks.count == 2, "exactly the two committed meal-log records")
        let (progress, completedEnrollment) = try ChallengeEvaluator.evaluate(
            definition: definition,
            enrollment: enrollment,
            cooks: cooks,
            revisionFor: { key in menu.first { $0.key == key } }
        )
        #expect(progress.qualifying.map(\.cookID).sorted() == ["cook-w41-curry", "cook-w41-stir"], "both lemon cooks count toward the goal")
        #expect(progress.excluded.isEmpty)
        #expect(progress.isComplete)
        #expect(progress.completion?.cookID == "cook-w41-curry", "the goal crossed on the curry — the cook that completed it")
        #expect(completedEnrollment?.completedByCookID == "cook-w41-curry", "the enrollment records the completing cook, derived from records")
        trace.record("d7-challenge", "challenge complete: 2 distinct lemon recipes derived from the week's cook records")

        // One identity, four consumers: the same cook ID the meal log wrote
        // is the ID the share path consumed and the challenge credited.
        #expect(shared.rating == 5 && shared.completedOn == "2026-10-06")
        trace.record("join", "cook record → meal log → share → challenge progress: one identity, four consumers")

        #expect(trace.count >= 20)
        let traceData = try trace.canonicalJSON()
        #expect(!traceData.isEmpty)
    }
}
