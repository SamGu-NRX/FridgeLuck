import Testing
import Foundation
import FLDomain
import FLFlowCore
import FLAssistantCore
import FLInventoryCore
import FLRecipeCore
import FLCommunityCore
import GRDB
@testable import FLScenarioKit

// S1 — the operator-specified week-long household arc, end to end on Linux:
// scan → reconcile → pick dinner → reject twice → cook with a swap → kill
// mid-cook → resume → complete → share to the table → run the challenge —
// asserting the cross-package contracts at every step (SPEC.md §3, PLAN.md
// suite A). Deterministic, offline, synthetic data only.
//
// Review round 2 recomposition: the arc now runs on the four fixed branches —
// the swap gate resolves composition itself through the canonical facts
// source and fails closed (join blocker 1), the pantry consumer and the
// claims fed to Tonight carry canonical allergen/diet properties and refuse
// what they cannot settle (join blocker 2), SharedCook construction passes
// the community export gate, and the assistant's session binding, live
// revision gate, and exactly-once execution are proven in-scenario (join
// blocker 3).

/// The device-side executor: a timer exists on the phone ONLY after the
/// authority executes the approved proposal (SPEC 3.6). The fixed
/// GRDBActionExecutor writes through the ledger's open transaction
/// connection, so the effect lands in the device's own table in the SAME
/// commit as the executed receipt — atomic by construction.
private struct DeviceTimerExecutor: GRDBActionExecutor {
    func apply(_ payload: ActionPayload, proposal: ActionProposal, in db: Database) throws {
        guard case let .timerCreate(label, seconds) = payload else {
            return
        }
        try db.execute(
            sql: "INSERT INTO fl_scenario_device_timer (proposalID, label, seconds, createdAtEpochSeconds) VALUES (?, ?, ?, ?)",
            arguments: [proposal.id, label, seconds, Int(proposal.createdAt.timeIntervalSince1970)]
        )
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

    // The claims the candidates carry are built by the world's facts-backed
    // builder (world.claims(for:restriction:householdConfirmed:)) — the join's
    // answer to round-2 blocker 2: composition resolved through the canonical
    // dataset, unresolved lines left absent to fail closed, the household's
    // recorded label-checks honored as explicit confirmations.

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

        // ── Seed (2026-09-19): flour and rice noodles bought 16 days before
        // the week starts — the staleness probes that go stale mid-scenario.
        // Rice noodles also anchor the pantry-engine's staleness contract on
        // a line whose peanut composition the facts CAN settle (free), so
        // staleness and composition-uncertainty are probed separately. ──
        let seedClock = WeekClock(startingAt: Week.day(-16, hour: 10))
        try world.ledger.apply(Fixtures.purchase(
            "ev-flour", "all-purpose flour", grams: 1000,
            household: hh, command: "cmd-seed-flour", at: seedClock.now,
            source: .receipt
        ))
        try world.ledger.apply(Fixtures.purchase(
            "ev-seed-noodles", "rice noodles", grams: 200,
            household: hh, command: "cmd-seed-noodles", at: seedClock.now,
            source: .receipt
        ))
        trace.record("seed", "all-purpose flour 1000g and rice noodles 200g purchased; by Tuesday both are past the 14-day reconfirm window")

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
        #expect(d1Events.count == 14, "full history intact, retractions included: \(d1Events.count) events (superseded ones are never deleted)")
        trace.record("d1-reconcile", "tomatoes corrected 600→540; mistaken yogurt retracted; history preserved")

        // ── Day 2 (Tue 17:30): Tonight — restrict, reject twice, swap. ──
        clock.advance(to: Week.day(2, hour: 17, minute: 30))
        #expect(clock.now == Week.day(2, hour: 17, minute: 30))

        // 1) Restrictions are filtered BEFORE ranking (SPEC 3.3) — and since
        //    the fixed flow (review round 2) fails closed, composition is
        //    resolved evidence, not a default. Two proposes make the
        //    fail-closed behavior visible in-scenario:
        //
        //    (a) BEFORE the household checks any label: the facts dataset
        //    cannot settle the peanut composition of most fresh lines, the
        //    fixed restriction check treats the unresolved lines as "needs
        //    confirmation", and NOTHING passes the hard filters — the honest
        //    empty state, never a silent pass. (Join blocker 2, first half.)
        //    (b) The household then checks ten labels (the app's
        //    ask-the-cook path); the confirmations are recorded evidence and
        //    the week's options appear. The peanut recipe stays blocked —
        //    a facts VIOLATION is not confirmable. (Join blocker 1 at
        //    ranking level: the block now rides facts-resolved composition.)
        let pantryNow = try world.pantryView(now: clock.now)
        let beforeConfirmation = try DinnerDecisionService.propose(
            candidates: menu.map { (revision: $0, claims: try world.claims(for: $0, restriction: restriction)) },
            context: context,
            pantry: pantryNow,
            reservations: StockLedger(pantry: pantryNow),
            now: clock.now
        )
        #expect(beforeConfirmation.state == .nothingFeasible,
            "with no composition evidence nothing passes the hard filters — the honest state, not a silent pass")
        #expect(beforeConfirmation.options.isEmpty)
        trace.record("d2-failclosed", "no composition evidence → nothing feasible (needs confirmation), never a silent pass")

        // The household checks the labels the dataset cannot settle. The
        // facts already settle rice noodles, coconut milk, and peanuts —
        // those need no confirmation.
        let labelConfirmed: Set<String> = [
            "broccoli", "sesame oil", "lemon", "olive oil", "all-purpose flour",
            "whole milk", "chickpeas", "tomatoes", "yogurt", "eggs",
        ]
        let candidates = try menu.map {
            (revision: $0, claims: try world.claims(for: $0, restriction: restriction, householdConfirmed: labelConfirmed))
        }
        let first = try DinnerDecisionService.propose(
            candidates: candidates,
            context: context,
            pantry: pantryNow,
            reservations: StockLedger(pantry: pantryNow),
            now: clock.now
        )
        #expect(!first.options.isEmpty, "after the recorded label-checks the week's options appear")
        #expect(first.options.allSatisfy { $0.title != "Peanut noodles" }, "the peanut recipe is filtered before ranking — through facts-resolved composition, not a declared default")
        #expect(first.state == .normal)
        trace.record("d2-restrict", "ten labels confirmed; Peanut noodles still blocked by the facts violation; \(first.options.count) options proposed")

        // 2) The stale probe through BOTH engines — now distinguishing the
        //    two refusals the fixed stack can report:
        //    · flow's fit lines know nothing of composition (the facts seam
        //      lives below flow): 17-day-old flour reads needsReconfirming;
        //    · the pantry engine, carrying canonical facts, refuses the SAME
        //      flour line as needsConfirmation — composition uncertainty
        //      outranks quantity staleness, and neither can read as cookable
        //      (join blocker 2, second half);
        //    · on a line whose peanut composition the facts CAN settle (rice
        //      noodles: resolved free), the pantry engine still reports
        //      staleness — the round-1 staleness contract intact.
        let pancakeOption = first.options.first { $0.title == "Flour pancakes" }
        let flowSaysStale = pancakeOption?.missing.contains { $0.canonicalName == "all-purpose flour" && $0.kind == .needsReconfirming }
        #expect(flowSaysStale == true, "flow's engine calls 17-day-old flour stale")
        if let flowSaysStale, flowSaysStale {
            trace.record("d2-stale-flow", "flow fit line: \(pancakeOption?.fit.display ?? "?")")
        }
        let pancakeReport = try FLPantryFeasibility.evaluate(
            recipe: menu[0],
            stock: try world.stock(),
            restriction: restriction,
            facts: world.facts,
            now: clock.now
        )
        #expect(pancakeReport.outcome != .complete, "stale or composition-unresolved evidence cannot read as fully cookable")
        let flourLine = try #require(pancakeReport.lines.first { $0.ingredient.canonicalName == "all-purpose flour" })
        #expect(flourLine.state == .needsConfirmation, "the pantry engine fails closed: the flour's peanut composition is not in the dataset — a refusal that asks the cook, never a silent pass")
        trace.record("d2-stale-composition", "flour line: needsConfirmation — unresolved composition outranks staleness (blocker 2 evidence)")

        let noodleBowl = Fixtures.revision("r-noodlebowl", title: "Rice noodle bowl", lines: [
            Fixtures.line("l1", "rice noodles", 250),
            Fixtures.line("l2", "coconut milk", 200),
            Fixtures.line("l3", "lemon", 30),
        ])
        let noodleReport = try FLPantryFeasibility.evaluate(
            recipe: noodleBowl,
            stock: try world.stock(),
            restriction: restriction,
            facts: world.facts,
            now: clock.now
        )
        let noodleLine = try #require(noodleReport.lines.first { $0.ingredient.canonicalName == "rice noodles" })
        #expect(noodleLine.state == .needsReconfirming, "same 17-day-old evidence, same staleness — on a line the facts can settle")
        trace.record("d2-stale", "rice noodles needsReconfirming in the pantry engine (17d > 14d window); composition resolved, so staleness surfaces")

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
            facts: world.facts,
            now: clock.now
        )
        #expect(stirReportNoSwap.missingIngredients.map(\.canonicalName).contains("sesame oil"))
        let sesameLine = try #require(stirReportNoSwap.lines.first { $0.ingredient.canonicalName == "sesame oil" })
        #expect(sesameLine.state == .needsConfirmation, "the engine refuses before the stock check: the sesame oil line's peanut composition is unresolved — unknown is a refusal, not a pass")
        #expect(stirReportNoSwap.outcome == .partial, "the bill cannot read complete while a line's composition is unsettled")
        let swap = try FLPantryFeasibility.FLAcceptedSwap(
            replacesGroupKey: FLStockFold.groupKey(for: Fixtures.ingredient("sesame oil")),
            substitute: Fixtures.ingredient("olive oil"),
            gramsFactor: 1.0
        )
        let stirReportSwapped = try FLPantryFeasibility.evaluate(
            recipe: stir,
            stock: try world.stock(),
            restriction: restriction,
            facts: world.facts,
            swaps: [swap],
            now: clock.now
        )
        #expect(stirReportSwapped.outcome == .partial, "an accepted swap cannot upgrade a composition refusal — fail closed holds under swaps too")
        let sesameLineSwapped = try #require(stirReportSwapped.lines.first { $0.ingredient.canonicalName == "sesame oil" })
        #expect(sesameLineSwapped.state == .needsConfirmation, "the swap rescue only covers a MISSING line; the composition refusal stands")
        // The gate's three verdicts, in-scenario (join blocker 1): olive
        // oil's peanut composition is not in the dataset → needs
        // confirmation (the app asks the cook); peanut oil is a facts
        // violation → refused outright, for Aiko, by name; after the
        // household checks the olive-oil label, the recorded confirmation
        // resolves the open question and the swap is accepted.
        let gateEaters = eaters.map {
            SwapGate.Eater(name: $0.name, restriction: Fixtures.restriction(allergens: $0.allergens, diets: $0.diets))
        }
        guard case .needsConfirmation(let ask) = SwapGate.decide(
            substitute: Fixtures.ingredient("olive oil"),
            eaters: gateEaters,
            facts: world.facts
        ) else {
            Issue.record("the gate must ask for confirmation on an unsettled substitute, not wave it through")
            return
        }
        #expect(ask.contains("olive oil"))
        trace.record("d2-swap-gate", "gate needs confirmation: \(ask)")

        guard case .refused(let whyNot) = SwapGate.decide(
            substitute: Fixtures.ingredient("peanut oil"),
            eaters: gateEaters,
            facts: world.facts
        ) else {
            Issue.record("peanut oil must be refused outright for Aiko")
            return
        }
        #expect(whyNot.contains("Aiko"), "the refusal names the eater it protects: \(whyNot)")
        trace.record("d2-swap-refuse", "peanut oil refused: \(whyNot)")

        guard case .allowed(let why) = SwapGate.decide(
            substitute: Fixtures.ingredient("olive oil"),
            eaters: gateEaters,
            facts: world.facts,
            householdConfirmed: ["olive oil"]
        ) else {
            Issue.record("the recorded label-check must resolve the open composition")
            return
        }
        trace.record("d2-swap", "olive-oil swap accepted after the recorded label-check: \(why)")

        // ── Day 2 (17:55): cook with the swap — flow's session takes over. ──
        clock.advance(minutes: 25)
        #expect(clock.now == Week.day(2, hour: 17, minute: 55))
        let startedAt = clock.now
        let cookSessionID = "cook-2026-w41-stir"
        var cook = try CookSession.start(sessionID: cookSessionID, revision: stir, now: clock.now)
        #expect(cook.stage == .cooking)
        trace.record("d2-cook-start", "session \(cookSessionID) started at 17:55 over \(stir.steps.count) steps")

        // The swap the gate accepted becomes part of the cook session
        // MID-COOK (round 2: substitutions are first-class on the session —
        // the join's hand-off workaround is about to be deleted, so this
        // acceptance is the only thing that can carry the swap into the
        // logged record).
        let confirmedSwap = try CookSubstitution(
            from: Fixtures.ingredient("sesame oil"),
            to: Fixtures.ingredient("olive oil"),
            necessity: .necessary
        )
        cook = try cook.accept(substitution: confirmedSwap)
        #expect(cook.acceptedSubstitutions.count == 1, "the swap is accepted on the live session")
        trace.record("d2-swap-accept", "olive-oil swap accepted mid-cook on the session")

        // The assistant earns a timer the device may only set after approval.
        let snapshot = try await AssistantContextBuilder(
            stateSource: WorldStateSource(
                lines: try world.assistantLines(),
                recipe: stir.key,
                step: cook.checkpoint.stepIndex
            ),
            revisionClock: world.revisionClock
        ).buildSnapshot(sessionID: cookSessionID, now: clock.now)
        let authority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
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
        // (a) Bound to the CALLER SESSION (round 2): a byte-identical
        //     approval presented from another session is refused and records
        //     nothing — the proposal stays open for its own session.
        let deviceTimers = DeviceTimerExecutor()
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(
                timerApproval, executor: deviceTimers,
                sessionID: "not-this-cook-session", now: clock.now
            )
        }
        #expect(try await world.receiptLedger.latestReceipt(proposalID: timerProposal.id)?.state == .pendingApproval,
            "a session mismatch records nothing — the proposal stays open for its own session")
        trace.record("d2-timer-session", "wrong-session approval refused; nothing recorded")

        // (b) Two interleaved approvals of the same proposal: exactly one
        //     wins — one device effect, one decision receipt
        //     (claim-before-any-await; join blocker 3).
        let raced = await withTaskGroup(of: Bool.self) { group in
            let racedNow = clock.now
            group.addTask { (try? await authority.approve(timerApproval, executor: deviceTimers, sessionID: cookSessionID, now: racedNow)) != nil }
            group.addTask { (try? await authority.approve(timerApproval, executor: deviceTimers, sessionID: cookSessionID, now: racedNow)) != nil }
            var outcomes: [Bool] = []
            for await ok in group { outcomes.append(ok) }
            return outcomes
        }
        #expect(raced.filter { $0 }.count == 1, "exactly one of the interleaved approvals succeeded")
        let armed = try world.createdDeviceTimers()
        #expect(armed.count == 1, "one approved proposal → exactly one device effect, committed with its executed receipt")
        cook = try cook.addTimer(
            id: "timer-1",
            label: armed[0].label,
            deadline: clock.now.addingTimeInterval(240),
            now: clock.now
        )
        let timerReceipt = try await world.receiptLedger.latestReceipt(proposalID: timerProposal.id)
        #expect(timerReceipt?.state == .executed, "the decision receipt is the executed one")
        trace.record("d2-timer", "two interleaved approvals → one device effect, one executed receipt (deadline 17:59)")

        // (c) The live revision gate (round 2): a second proposal is minted
        //     against the current context; the session's state then advances
        //     (step 1 completes; the host bumps the revision clock with it);
        //     the approval arrives AFTER the advance and is refused at the
        //     execution gate — stale revision, no effect, no second timer.
        let lateSnapshot = try await AssistantContextBuilder(
            stateSource: WorldStateSource(
                lines: try world.assistantLines(),
                recipe: stir.key,
                step: cook.checkpoint.stepIndex
            ),
            revisionClock: world.revisionClock
        ).buildSnapshot(sessionID: cookSessionID, now: clock.now)
        let ricePayload = ActionPayload.timerCreate(label: "Start the rice", seconds: 600)
        let lateProposal = try await authority.propose(
            from: try ToolInvocation(tool: .proposeTimer, payload: ricePayload),
            against: lateSnapshot,
            now: clock.now
        )
        let lateApproval = try ActionApproval(
            proposalID: lateProposal.id,
            payloadHash: try FLPayloadHashing.payloadHash(ricePayload),
            snapshotRevision: lateSnapshot.revision,
            approvedAt: clock.now
        )

        // Step 1 completes; the process is then killed at 18:00.
        clock.advance(minutes: 5)
        cook = try cook.completeStep(now: clock.now)
        #expect(cook.checkpoint.stepIndex == 1)
        _ = await world.revisionClock.bump()
        trace.record("d2-advance", "step 1 complete at 18:00; the session state — and the context revision — advanced")

        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(
                lateApproval, executor: deviceTimers,
                sessionID: cookSessionID, now: clock.now
            )
        }
        let staleReceipt = try await world.receiptLedger.latestReceipt(proposalID: lateProposal.id)
        #expect(staleReceipt?.state == .staleRevision, "the live revision gate refuses an approval granted against a snapshot that has since advanced")
        #expect(try world.createdDeviceTimers().count == 1, "still exactly one device effect")
        trace.record("d2-stale-gate", "approval granted pre-advance, presented post-advance → staleRevision, no effect")

        // The household re-asks on a fresh snapshot, then thinks better of
        // it: the decline is a decision receipt too.
        let freshSnapshot = try await AssistantContextBuilder(
            stateSource: WorldStateSource(
                lines: try world.assistantLines(),
                recipe: stir.key,
                step: cook.checkpoint.stepIndex
            ),
            revisionClock: world.revisionClock
        ).buildSnapshot(sessionID: cookSessionID, now: clock.now)
        let freshProposal = try await authority.propose(
            from: try ToolInvocation(tool: .proposeTimer, payload: ricePayload),
            against: freshSnapshot,
            now: clock.now
        )
        try await authority.decline(proposalID: freshProposal.id, now: clock.now)
        #expect(try await world.receiptLedger.latestReceipt(proposalID: freshProposal.id)?.state == .rejected)
        trace.record("d2-decline", "fresh rice-timer proposal declined; rejected receipt")
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
        // Round 2 contract: the checkpoint stays BARE (completed steps and
        // timers only) — accepted substitutions are app-side state, and the
        // app re-applies them from its own record after a restart. The join
        // models exactly that, so the swap survives the kill end to end; the
        // hand-off below then carries it first-class. (Recorded in the PR
        // Handoff: carrying substitutions IN the checkpoint would be a flow
        // contract change, not a join fix.)
        cook = try cook.accept(substitution: confirmedSwap)
        #expect(cook.acceptedSubstitutions.count == 1, "re-applied once on the resumed session — carried again, no duplicate")
        trace.record("d2-resume", "recovered at step 2 of \(stepIDs.count); expired timer acknowledged; app-side swap re-applied")

        // The remaining steps finish.
        clock.advance(minutes: 4)
        cook = try cook.completeStep(now: clock.now)
        clock.advance(minutes: 3)
        cook = try cook.completeStep(now: clock.now)
        #expect(cook.stage == .finished)
        trace.record("d2-finish", "all steps complete at 18:17; stage .finished")

        // ── Complete: the meal-log hand-off. Round 2: makeHandoff carries
        // the session's accepted substitutions first-class (FLDomain
        // Cook(substitutions:)) — the join's post-hoc Cook-reconstruction
        // workaround is DELETED. The red-first capture: with the workaround
        // gone and no session acceptance, this assertion failed (the logged
        // Cook carried no substitutions at the reviewed head). ──
        let handoff = try MealLog.makeHandoff(
            session: cook,
            cookID: "cook-w41-stir",
            eventID: "evt-w41-stir",
            servings: 2,
            rating: 5,
            wouldRepeat: true,
            note: nil,
            startedAt: startedAt
        )
        let finalCook = handoff.cook
        #expect(finalCook.substitutions.count == 1, "the swap accepted mid-cook flows from the SESSION into the record — no join workaround")
        #expect(finalCook.substitutions[0].to.canonicalName == "olive oil")
        try MealLog.commit(handoff, db: world.db)
        let logged = try world.loggedCooks()
        #expect(logged.count == 1)
        #expect(logged[0].id == "cook-w41-stir")
        #expect(logged[0].substitutions.count == 1, "the swap survived the mid-cook restart into the durable cook record")
        trace.record("d2-meallog", "meal-log committed atomically: cook + preference event, swap carried by makeHandoff from the session")

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

        // ── Share to the table (Tuesday evening). Round 2: SharedCook
        // construction passes the community export gate (recipe rights) —
        // the same gate #106's export path uses (join blocker 3, share
        // half). ──
        clock.advance(hours: 1)
        let day2 = Week.dayString(for: clock.now)
        let shared = try SharedCook(cook: finalCook, revision: stir, completedOn: day2)
        #expect(shared.servings == 2)
        #expect(shared.rating == 5)
        #expect(shared.swaps.count == 1, "the swap the session carried is now in the SHARED payload too")
        #expect(shared.swaps[0].to.canonicalName == "olive oil")
        #expect(shared.swaps[0].necessity == .necessary)
        #expect(shared.completedOn == "2026-10-06", "the share carries the day, never the instant (SPEC 3.4)")
        trace.record("d2-share", "SharedCook built for \(day2) with 1 recorded swap — through the community export gate")

        // The negative half of the same gate: a cook of a revision the
        // rights metadata cannot vouch for cannot become a SharedCook at
        // all — the refusal is explicit, never a silent export.
        let mystery = Fixtures.revision("r-mystery", title: "Mystery bake", lines: [
            Fixtures.line("l1", "yogurt", 100),
        ], license: Fixtures.unknownRightsLicense())
        let mysteryCook = try Cook(
            id: "cook-mystery",
            recipeRevision: mystery.key,
            servings: 2,
            substitutions: [],
            rating: 4,
            note: nil,
            startedAt: clock.now.addingTimeInterval(-3600),
            completedAt: clock.now
        )
        await #expect(throws: FLDomainError.self) {
            _ = try SharedCook(cook: mysteryCook, revision: mystery, completedOn: day2)
        }
        trace.record("d2-share-gate", "unknown-rights revision refused at SharedCook construction — quarantine, not silence")

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
