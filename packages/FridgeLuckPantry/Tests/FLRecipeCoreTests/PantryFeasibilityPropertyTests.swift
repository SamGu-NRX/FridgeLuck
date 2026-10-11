import XCTest
import FLDomain
import FLInventoryCore
@testable import FLRecipeCore

/// PLAN suite A: seeded property tests over random pantries and recipes,
/// plus an audit set of 200 pantry/recipe pairs. Pass bar:
/// 0 stock counted twice; 0 "sufficient" claims without evidence; fit-line
/// text correct on 200 of 200 pairs.
///
/// Labels come from a reference oracle written as a direct transcription of
/// SPEC 3.2 (its own allocation model and fit-line templates), never from
/// the implementation. The count gate fails loudly on missing rows — an
/// audit that passes silently on 184 of 200 pairs is not an audit — and a
/// planted-failure test proves the comparator can fail.
final class PantryFeasibilityPropertyTests: XCTestCase {
    // MARK: Deterministic randomness (SplitMix64 — stable on all platforms)

    struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_8CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(nextUInt64() % UInt64(range.count))
        }
        mutating func pick<T>(_ items: [T]) -> T {
            items[Int(nextUInt64() % UInt64(items.count))]
        }
        mutating func bool(_ probability: Int, of parts: Int) -> Bool {
            Int(nextUInt64() % UInt64(parts)) < probability
        }
    }

    // MARK: The synthetic world

    private static let day: TimeInterval = 86_400
    /// Fixed epoch: 2026-10-15T10:13:20Z. No wall-clock anywhere in this
    /// suite — every scenario must replay byte-for-byte from its seed.
    private static let baseEpoch: TimeInterval = 1_792_000_000

    private struct UniverseMember {
        let name: String
        let fdc: Int?
        let local: Int64?
    }

    /// One identity each; lines and purchases share the reference so groups
    /// line up (the conservative split for mismatched identities has its own
    /// unit tests).
    private static let universe: [UniverseMember] = [
        UniverseMember(name: "all-purpose flour", fdc: 168_894, local: nil),
        UniverseMember(name: "whole milk", fdc: 746_778, local: nil),
        UniverseMember(name: "butter", fdc: 173_430, local: nil),
        UniverseMember(name: "margarine", fdc: nil, local: 901),
        UniverseMember(name: "egg", fdc: nil, local: 902),
        UniverseMember(name: "granulated sugar", fdc: 169_655, local: nil),
        UniverseMember(name: "salt", fdc: nil, local: 903),
        UniverseMember(name: "olive oil", fdc: nil, local: 904),
        UniverseMember(name: "yellow onion", fdc: 170_000, local: nil),
        UniverseMember(name: "garlic", fdc: 170_108, local: nil),
        UniverseMember(name: "parsley", fdc: nil, local: 905),
        UniverseMember(name: "black pepper", fdc: nil, local: 906),
    ]
    private static let stapleNames: Set<String> = ["salt", "olive oil", "black pepper"]
    private static let swapMargarine: (UniverseMember, UniverseMember, Double) =
        (universe[2], universe[3], 1.0) // butter → margarine
    private static let swapOnion: (UniverseMember, UniverseMember, Double) =
        (universe[8], universe[9], 1.0) // yellow onion → garlic

    private func reference(_ member: UniverseMember) -> IngredientReference {
        RecipeFixtures.ingredient(member.name, fdc: member.fdc, local: member.local)
    }

    // MARK: Scenario

    private struct Scenario {
        var recipe: RecipeRevision
        var stock: [FLItemStock]
        var restriction: Restriction
        var swaps: [FLPantryFeasibility.FLAcceptedSwap]
        var staples: Set<String>
        var targetServings: Int?
        var now: Date
        var reconfirmWindow: TimeInterval?
    }

    /// One seeded scenario. Deterministic in the seed alone.
    private func makeScenario(seed: UInt64) throws -> Scenario {
        var rng = SeededRandom(seed: seed)
        let now = Date(timeIntervalSince1970: Self.baseEpoch + Double(rng.int(0...40)) * Self.day)

        // Recipe: 2-4 required lines, maybe one garnish. Duplicate
        // ingredients across lines are deliberate — they stress allocation.
        let lineCount = rng.int(2...4)
        var lines: [IngredientLine] = []
        var nextLine = 1
        for _ in 0..<lineCount {
            let member = rng.pick(Self.universe)
            lines.append(try RecipeFixtures.makeLine(
                "l\(nextLine)",
                ingredient: reference(member),
                grams: rng.bool(2, of: 10) ? nil : Double(rng.int(5...800)),
                preparation: rng.bool(3, of: 10) ? rng.pick(["chopped", "cooked"]) : nil
            ))
            nextLine += 1
        }
        var garnishLines: [IngredientLine] = []
        if rng.bool(1, of: 3) {
            let member = rng.pick(Self.universe)
            garnishLines.append(try RecipeFixtures.makeLine(
                "g1",
                ingredient: reference(member),
                grams: rng.bool(2, of: 10) ? nil : Double(rng.int(10...50)),
                preparation: rng.bool(2, of: 10) ? rng.pick(["chopped", "cooked"]) : nil,
                isOptionalGarnish: true
            ))
        }

        // Policy: restrictions 20%, an accepted swap 40%, an extra staple
        // name 10%; staleness is a policy too, so nil window is common.
        let restriction: Restriction
        if rng.bool(1, of: 5) {
            restriction = try Restriction(customExclusions: [rng.pick(Self.universe).name])
        } else {
            restriction = try Restriction()
        }
        var swaps: [FLPantryFeasibility.FLAcceptedSwap] = []
        var swapConfig: (UniverseMember, UniverseMember, Double)?
        if rng.bool(2, of: 5) {
            let config = rng.bool(1, of: 2) ? Self.swapMargarine : Self.swapOnion
            swapConfig = config
            swaps.append(try FLPantryFeasibility.FLAcceptedSwap(
                replacesGroupKey: FLStockFold.groupKey(for: reference(config.0)),
                substitute: reference(config.1),
                gramsFactor: rng.bool(1, of: 2) ? config.2 : rng.pick([0.5, 1.0, 2.0])
            ))
        }

        // Make the audit SEE the contract's most distinctive shape — a bill
        // completed through an accepted swap ("1 of 2 · 1 swap"). In random
        // pantries that shape is vanishingly rare, and an audit that never
        // exercises it cannot verify the swap-suffix template. Half the swap
        // scenarios force a complete bill; the rest leave the other lines
        // random (a partial bill with an attributed swap).
        var forceComplete = false
        if let (from, _, _) = swapConfig {
            lines[0] = try RecipeFixtures.makeLine(
                "l1",
                ingredient: reference(from),
                grams: Double(rng.int(50...400)),
                preparation: rng.bool(1, of: 4) ? "chopped" : nil
            )
            forceComplete = rng.bool(1, of: 2)
            if forceComplete {
                // An unknown requirement can never be satisfied, so a
                // complete bill also needs every other line measured.
                for index in 1..<lines.count where lines[index].quantity.gramsIfKnown == nil {
                    forceComplete = false
                }
            }
        }

        // Pantry: 0-6 random lots — never of a swap's replaced ingredient
        // (the rescue needs the shelf to lack it); some uncounted; some
        // stale; a few scenarios consume a quarter of a known lot.
        var events: [FLStockEvent] = []
        let lotCount = rng.int(0...6)
        for i in 0..<lotCount {
            let member = rng.pick(Self.universe)
            if let (from, _, _) = swapConfig, member.name == from.name {
                continue
            }
            let purchased = rng.bool(3, of: 20) ? nil : Double(rng.int(50...1000))
            let boughtAt = now - Double(rng.int(0...10)) * Self.day
            let isStaleLot = rng.bool(1, of: 2)
            let timestamp = isStaleLot
                ? now - Double(rng.int(20...90)) * Self.day
                : boughtAt
            events.append(RecipeFixtures.purchase(
                "p\(i)", ingredient: reference(member), grams: purchased,
                preparation: rng.bool(2, of: 10) ? rng.pick(["chopped", "cooked"]) : nil,
                timestamp: timestamp
            ))
            if let grams = purchased, rng.bool(3, of: 10) {
                events.append(RecipeFixtures.consume(
                    "c\(i)", ingredient: reference(member), grams: grams / 4,
                    timestamp: timestamp + Self.day
                ))
            }
        }
        // The substitute is stocked generously and fresh, so the rescue is
        // real (a stale substitute flips the line to needsReconfirming —
        // its own dedicated test).
        if let (_, to, _) = swapConfig {
            events.append(RecipeFixtures.purchase(
                "pswap", ingredient: reference(to), grams: 10_000, timestamp: now - Self.day
            ))
        }
        // A forced-complete bill covers every remaining line generously.
        if forceComplete {
            for index in 1..<lines.count {
                events.append(RecipeFixtures.purchase(
                    "pc\(index)", ingredient: lines[index].ingredient, grams: 10_000, timestamp: now - Self.day
                ))
            }
        }
        let stock = try RecipeFixtures.stock(events)

        var staples = Self.stapleNames
        if rng.bool(1, of: 10) {
            staples.insert(rng.pick(Self.universe).name)
        }

        return Scenario(
            recipe: try RecipeRevision(
                key: RecipeKey(source: .user, sourceRecipeID: "property-\(seed)", revision: 1),
                title: "Property Recipe",
                servingBasis: ServingBasis(servings: 2),
                ingredientLines: lines + garnishLines,
                steps: [Step(stepID: "s1", action: "Cook everything together")],
                source: RecipeSourceEvidence(origin: .user, attribution: nil, license: RecipeFixtures.makeLicense())
            ),
            stock: stock,
            restriction: restriction,
            swaps: swaps,
            staples: staples,
            targetServings: rng.bool(2, of: 5) ? rng.pick([2, 3, 4]) : nil,
            now: now,
            reconfirmWindow: rng.bool(3, of: 5) ? nil : 14 * Self.day
        )
    }

    // MARK: The reference oracle — a direct transcription of SPEC 3.2

    private struct OracleLot {
        var remaining: Double? // nil = uncounted
        var preparation: String?
        var lastConfirmedAt: Date?
    }

    private struct ExpectedLine: Equatable {
        var state: FLFeasibilityLineState
        var viaSwap: Bool
    }

    private struct Expected: Equatable {
        var lines: [ExpectedLine]
        var garnish: [ExpectedLine]
        var outcome: FLFeasibilityReport.Outcome
        var fitLine: String
        var missingKeys: [String]
    }

    /// Independent labelling. Written from the SPEC contract text, not from
    /// PantryFeasibility.swift; preparation compatibility uses the M1-tested
    /// FLPreparationTransforms primitive.
    private func oracleLabel(_ scenario: Scenario) throws -> Expected {
        let transforms = FLPreparationTransforms.standard
        let scale = Double(scenario.targetServings ?? 2) / 2.0
        var pool: [String: [OracleLot]] = [:]
        for item in scenario.stock {
            pool[item.groupKey] = item.lots.map { lot in
                OracleLot(
                    remaining: lot.remaining.gramsIfKnown?.grams,
                    preparation: lot.preparation,
                    lastConfirmedAt: lot.lastConfirmedAt
                )
            }
        }

        func isStale(_ lots: [OracleLot]) -> Bool {
            guard let window = scenario.reconfirmWindow else { return false }
            guard let freshest = lots.compactMap(\.lastConfirmedAt).max() else { return true }
            return freshest < scenario.now.addingTimeInterval(-window)
        }

        // FIFO draw of `take` grams across the given lots (by index list).
        func draw(_ groupKey: String, from indices: [Int], grams: Double) {
            var remaining = grams
            for index in indices {
                guard remaining > 0 else { break }
                if let lotRemaining = pool[groupKey]![index].remaining, lotRemaining > 0 {
                    let taken = min(lotRemaining, remaining)
                    pool[groupKey]![index].remaining = lotRemaining - taken
                    remaining -= taken
                }
            }
        }

        // Zero out what a short line shows (contract: the cook uses it).
        func zero(_ groupKey: String, indices: [Int]) {
            for index in indices {
                pool[groupKey]![index].remaining = 0
            }
        }

        func swapRescue(line: IngredientLine, key: String, required: Double?, doesReserve: Bool) -> ExpectedLine? {
            guard let swap = scenario.swaps.first(where: { $0.replacesGroupKey == key }),
                  scenario.restriction.permits(canonicalName: swap.substitute.canonicalName) else { return nil }
            let substituteKey = FLStockFold.groupKey(for: swap.substitute)
            guard let required,
                  let lots = pool[substituteKey], !lots.isEmpty else { return nil }
            let substituteRequired = required * swap.gramsFactor
            let usableIndices = lots.indices.filter {
                transforms.lotUsable(forLine: line.preparation, lotPreparation: lots[$0].preparation)
            }
            let usable = usableIndices.map { lots[$0] }
            guard !usable.isEmpty, usable.allSatisfy({ $0.remaining != nil }) else { return nil }
            let total = usable.compactMap(\.remaining).reduce(0, +)
            guard total >= substituteRequired else { return nil }
            let stale = isStale(usable)
            if doesReserve && !stale { draw(substituteKey, from: Array(usableIndices), grams: substituteRequired) }
            return ExpectedLine(state: stale ? .needsReconfirming : .satisfied, viaSwap: !stale)
        }

        func judge(_ line: IngredientLine, doesReserve: Bool) -> ExpectedLine {
            let key = FLStockFold.groupKey(for: line.ingredient)
            let required = line.quantity.gramsIfKnown.map { $0.grams * scale }

            // Hard restrictions are absolute.
            guard scenario.restriction.permits(canonicalName: line.ingredient.canonicalName) else {
                return ExpectedLine(state: .blockedByRestriction, viaSwap: false)
            }
            guard let lots = pool[key], !lots.isEmpty else {
                // A staple with no record at all is assumed, never evidence.
                if scenario.staples.contains(line.ingredient.canonicalName.lowercased()) {
                    return ExpectedLine(state: .assumedStaple, viaSwap: false)
                }
                if let swapped = swapRescue(line: line, key: key, required: required, doesReserve: doesReserve) {
                    return swapped
                }
                return ExpectedLine(state: .missing, viaSwap: false)
            }

            func assess(_ candidateLots: [OracleLot], required: Double?) -> FLFeasibilityLineState {
                let usable = candidateLots.filter {
                    transforms.lotUsable(forLine: line.preparation, lotPreparation: $0.preparation)
                }
                guard !usable.isEmpty else { return .missing }
                guard let required else {
                    return .uncertainStock
                }
                guard usable.allSatisfy({ $0.remaining != nil }) else { return .uncertainStock }
                let total = usable.compactMap(\.remaining).reduce(0, +)
                if total >= required {
                    return isStale(usable) ? .needsReconfirming : .satisfied
                } else if total > 0 {
                    return isStale(usable) ? .needsReconfirming : .short
                }
                return .missing
            }

            let asked = assess(lots, required: required)

            // An accepted swap may cover a line the asked-for identity cannot.
            if asked == .missing,
               let swap = scenario.swaps.first(where: { $0.replacesGroupKey == key }),
               scenario.restriction.permits(canonicalName: swap.substitute.canonicalName) {
                let substituteKey = FLStockFold.groupKey(for: swap.substitute)
                let substituteLots = pool[substituteKey] ?? []
                let substituteRequired = required.map { $0 * swap.gramsFactor }
                let usableIndices = substituteLots.indices.filter {
                    transforms.lotUsable(forLine: line.preparation, lotPreparation: substituteLots[$0].preparation)
                }
                let usable = usableIndices.map { substituteLots[$0] }
                if let substituteRequired, !usable.isEmpty, usable.allSatisfy({ $0.remaining != nil }) {
                    let total = usable.compactMap(\.remaining).reduce(0, +)
                    if total >= substituteRequired {
                        if doesReserve {
                            draw(substituteKey, from: Array(usableIndices), grams: substituteRequired)
                        }
                        let stale = isStale(usable)
                        return ExpectedLine(state: stale ? .needsReconfirming : .satisfied, viaSwap: !stale)
                    }
                }
                // Not covered: the asked-for identity's own evidence decides.
            }

            // Reserve or consume exactly what the decided line shows.
            let usableIndices = lots.indices.filter {
                transforms.lotUsable(forLine: line.preparation, lotPreparation: lots[$0].preparation)
            }
            switch asked {
            case .satisfied:
                if doesReserve, let required {
                    draw(key, from: Array(usableIndices), grams: required)
                }
            case .short:
                if doesReserve {
                    zero(key, indices: Array(usableIndices))
                }
            default:
                break
            }
            return ExpectedLine(state: asked, viaSwap: false)
        }

        var expectedLines: [ExpectedLine] = []
        for line in scenario.recipe.requiredIngredientLines {
            expectedLines.append(judge(line, doesReserve: true))
        }
        var expectedGarnish: [ExpectedLine] = []
        for line in scenario.recipe.ingredientLines where line.isOptionalGarnish {
            expectedGarnish.append(judge(line, doesReserve: false))
        }

        let outcome: FLFeasibilityReport.Outcome = expectedLines.allSatisfy { $0.state == .satisfied }
            ? .complete
            : (expectedLines.contains { $0.state == .blockedByRestriction } ? .blocked : .partial)

        let fitLine = oracleFitLine(
            requiredLines: scenario.recipe.requiredIngredientLines,
            expected: expectedLines
        )

        var seen: Set<String> = []
        var missingKeys: [String] = []
        for (index, line) in scenario.recipe.requiredIngredientLines.enumerated() where expectedLines[index].state != .satisfied {
            let key = FLStockFold.groupKey(for: line.ingredient)
            if seen.insert(key).inserted {
                missingKeys.append(key)
            }
        }

        return Expected(
            lines: expectedLines,
            garnish: expectedGarnish,
            outcome: outcome,
            fitLine: fitLine,
            missingKeys: missingKeys
        )
    }

    /// The SPEC 3.2 templates, written independently of the implementation:
    /// "9 of 10 · 1 swap" only when every line is satisfied; otherwise
    /// "N recorded · check …" naming up to three problem lines in bill
    /// order. Never a percentage, never a cookability claim.
    private func oracleFitLine(requiredLines: [IngredientLine], expected: [ExpectedLine]) -> String {
        guard !expected.isEmpty else {
            return "Nothing to check — this revision has no ingredient lines."
        }
        if let blockedIndex = expected.firstIndex(where: { $0.state == .blockedByRestriction }) {
            let name = requiredLines[blockedIndex].ingredient.canonicalName
            return "Blocked — \(name) is excluded by this household's hard restrictions."
        }
        let swapCount = expected.filter(\.viaSwap).count
        if expected.allSatisfy({ $0.state == .satisfied }) {
            let suffix = swapCount > 0 ? " · \(swapCount) swap\(swapCount == 1 ? "" : "s")" : ""
            return "\(expected.count - swapCount) of \(expected.count)\(suffix)"
        }
        let recorded = expected.filter { $0.state == .satisfied }.count
        let names = requiredLines
            .enumerated()
            .filter { expected[$0.offset].state != .satisfied }
            .map { $0.element.ingredient.canonicalName }
        let problemNames = names.prefix(3)
        let named: String
        switch problemNames.count {
        case 1: named = String(problemNames[0])
        case 2: named = "\(problemNames[0]) and \(problemNames[1])"
        default: named = "\(problemNames[0]), \(problemNames[1]) and \(problemNames[2])"
        }
        return "\(recorded) recorded · check \(named)"
    }

    // MARK: The audit comparator

    private func auditDiffs(report: FLFeasibilityReport, expected: Expected) -> [String] {
        var diffs: [String] = []
        if report.lines.count != expected.lines.count {
            diffs.append("line count \(report.lines.count) != \(expected.lines.count)")
            return diffs
        }
        for (index, line) in report.lines.enumerated() where line.state != expected.lines[index].state {
            diffs.append("line \(index) state \(line.state.rawValue) != \(expected.lines[index].state.rawValue)")
        }
        for (index, line) in report.lines.enumerated() where line.viaSwap != expected.lines[index].viaSwap {
            diffs.append("line \(index) viaSwap \(line.viaSwap) != \(expected.lines[index].viaSwap)")
        }
        if report.garnishLines.map(\.state) != expected.garnish.map(\.state) {
            diffs.append("garnish states \(report.garnishLines.map(\.state.rawValue)) != \(expected.garnish.map(\.state.rawValue))")
        }
        if report.outcome != expected.outcome {
            diffs.append("outcome \(report.outcome.rawValue) != \(expected.outcome.rawValue)")
        }
        if report.fitLine != expected.fitLine {
            diffs.append("fitLine \(report.fitLine.debugDescription) != \(expected.fitLine.debugDescription)")
        }
        let missingKeys = report.missingIngredients.map { FLStockFold.groupKey(for: $0) }
        if missingKeys != expected.missingKeys {
            diffs.append("missing \(missingKeys) != \(expected.missingKeys)")
        }
        return diffs
    }

    // MARK: Audit set: 200 pairs, 200 of 200 correct

    /// The audit set is exactly 200 pairs. A shorter generated set must fail
    /// the suite, never pass silently.
    func testAuditSetContainsExactly200Pairs() throws {
        var count = 0
        for seed in UInt64(1)...200 {
            _ = try makeScenario(seed: seed)
            count += 1
        }
        XCTAssertEqual(count, 200, "the suite-A audit set must hold 200 pantry/recipe pairs, got \(count)")
    }

    func test200PairAuditMatchesTheReferenceOracle() throws {
        var audited = 0
        var fitLineMatches = 0
        var swapCompleteCases = 0
        for seed in UInt64(1)...200 {
            let scenario = try makeScenario(seed: seed)
            let report = try FLPantryFeasibility.evaluate(
                recipe: scenario.recipe,
                stock: scenario.stock,
                restriction: scenario.restriction,
                staples: scenario.staples,
                swaps: scenario.swaps,
                targetServings: scenario.targetServings,
                now: scenario.now,
                reconfirmWindow: scenario.reconfirmWindow
            )
            let expected = try oracleLabel(scenario)
            let diffs = auditDiffs(report: report, expected: expected)
            XCTAssertTrue(
                diffs.isEmpty,
                "seed \(seed) disagrees with the SPEC oracle: \(diffs.joined(separator: "; "))"
            )
            if report.fitLine == expected.fitLine { fitLineMatches += 1 }
            if report.outcome == .complete && report.lines.contains(where: \.viaSwap) {
                swapCompleteCases += 1
            }
            audited += 1
        }
        XCTAssertEqual(audited, 200, "audited pairs must be 200 of 200")
        XCTAssertEqual(fitLineMatches, 200, "PLAN suite A: fit-line text correct on 200 of 200 pairs")
        XCTAssertGreaterThan(
            swapCompleteCases, 0,
            "the 200 pairs never completed a bill through an accepted swap — the audit cannot verify the swap-suffix template and this pass is vacuous"
        )
    }

    /// Planted failure: a deliberately corrupted label must be caught. If
    /// this ever fails, the comparator passes everything and the audit
    /// means nothing.
    func testPlantedLabelFailureIsCaught() throws {
        let scenario = try makeScenario(seed: 7)
        let report = try FLPantryFeasibility.evaluate(
            recipe: scenario.recipe,
            stock: scenario.stock,
            restriction: scenario.restriction,
            staples: scenario.staples,
            swaps: scenario.swaps,
            targetServings: scenario.targetServings,
            now: scenario.now,
            reconfirmWindow: scenario.reconfirmWindow
        )
        let expected = try oracleLabel(scenario)
        var corrupted = expected
        corrupted.fitLine = "you have everything you need!"
        XCTAssertFalse(
            auditDiffs(report: report, expected: corrupted).isEmpty,
            "the comparator must catch a corrupted label"
        )
    }

    // MARK: Property: 0 stock counted twice

    /// Across 50 seeds: the reserves a report shows (satisfied requirements
    /// plus what short lines show) never exceed the counted stock of that
    /// ingredient group in the input pantry.
    func testNoStockIsCountedTwiceAcrossSeeds() throws {
        for seed in UInt64(1)...50 {
            let scenario = try makeScenario(seed: seed + 1_000)
            let report = try FLPantryFeasibility.evaluate(
                recipe: scenario.recipe,
                stock: scenario.stock,
                restriction: scenario.restriction,
                staples: scenario.staples,
                swaps: scenario.swaps,
                targetServings: scenario.targetServings,
                now: scenario.now,
                reconfirmWindow: scenario.reconfirmWindow
            )

            var countedStock: [String: Double] = [:]
            for item in scenario.stock {
                let total = item.lots.compactMap { $0.remaining.gramsIfKnown?.grams }.reduce(0, +)
                countedStock[item.groupKey, default: 0] += total
            }
            var reserved: [String: Double] = [:]
            for line in report.lines {
                let key = FLStockFold.groupKey(for: line.ingredient)
                // A swap-rescued line draws from the SUBSTITUTE's stock,
                // not the replaced ingredient's.
                let drawKey: String
                if line.viaSwap, let swap = scenario.swaps.first(where: { $0.replacesGroupKey == key }) {
                    drawKey = FLStockFold.groupKey(for: swap.substitute)
                } else {
                    drawKey = key
                }
                switch line.state {
                case .satisfied:
                    reserved[drawKey, default: 0] += line.requiredGrams ?? 0
                case .short:
                    reserved[drawKey, default: 0] += line.availableGrams ?? 0
                default:
                    break
                }
            }
            for (key, amount) in reserved {
                let available = countedStock[key] ?? 0
                XCTAssertLessThanOrEqual(
                    amount, available + 0.001,
                    "seed \(seed + 1_000): group '\(key)' reserves \(amount) g but the pantry only holds \(available) g — stock counted twice"
                )
            }
        }
    }

    // MARK: Property: 0 "sufficient" without evidence

    /// Across 50 seeds: a complete outcome stands only on satisfied lines
    /// with counted numbers behind them, and the fit line never claims more
    /// than the outcome does.
    func testNoSufficientClaimWithoutEvidenceAcrossSeeds() throws {
        for seed in UInt64(1)...50 {
            let scenario = try makeScenario(seed: seed + 2_000)
            let report = try FLPantryFeasibility.evaluate(
                recipe: scenario.recipe,
                stock: scenario.stock,
                restriction: scenario.restriction,
                staples: scenario.staples,
                swaps: scenario.swaps,
                targetServings: scenario.targetServings,
                now: scenario.now,
                reconfirmWindow: scenario.reconfirmWindow
            )

            if report.outcome == .complete {
                for line in report.lines {
                    XCTAssertEqual(line.state, .satisfied, "seed \(seed + 2_000): complete outcome over a \(line.state.rawValue) line")
                    XCTAssertNotNil(line.requiredGrams, "seed \(seed + 2_000): satisfied line without a known requirement")
                    XCTAssertNotNil(line.availableGrams, "seed \(seed + 2_000): satisfied line without counted stock")
                    if let required = line.requiredGrams, let available = line.availableGrams {
                        XCTAssertGreaterThanOrEqual(available + 0.001, required, "seed \(seed + 2_000): satisfied line where stock is short")
                    }
                }
                XCTAssertFalse(report.fitLine.lowercased().contains("check"), "seed \(seed + 2_000): a complete bill never asks to check anything")
                XCTAssertTrue(report.fitLine.contains(" of "), "seed \(seed + 2_000): complete fit line must be the N-of-N shape, got '\(report.fitLine)'")
            } else if report.outcome == .partial {
                XCTAssertTrue(
                    report.fitLine.contains("check") || report.fitLine.lowercased().contains("nothing"),
                    "seed \(seed + 2_000): a partial bill must name what to check, got '\(report.fitLine)'"
                )
                XCTAssertFalse(report.fitLine.lowercased().contains("can cook"), "seed \(seed + 2_000): a partial bill never suggests cookability")
                XCTAssertFalse(report.fitLine.contains("%"), "seed \(seed + 2_000): a fit line never states a percentage")
            } else {
                XCTAssertTrue(report.fitLine.lowercased().contains("blocked"), "seed \(seed + 2_000): a blocked bill says so, got '\(report.fitLine)'")
            }
        }
    }

    // MARK: Property: swap attribution only on satisfied lines

    func testSwapAttributionOnlyOnSatisfiedLinesAcrossSeeds() throws {
        var swapLinesTotal = 0
        for seed in UInt64(1)...50 {
            let scenario = try makeScenario(seed: seed + 3_000)
            let report = try FLPantryFeasibility.evaluate(
                recipe: scenario.recipe,
                stock: scenario.stock,
                restriction: scenario.restriction,
                staples: scenario.staples,
                swaps: scenario.swaps,
                targetServings: scenario.targetServings,
                now: scenario.now,
                reconfirmWindow: scenario.reconfirmWindow
            )
            for line in report.lines where line.viaSwap {
                XCTAssertEqual(line.state, .satisfied, "seed \(seed + 3_000): swap attribution only attaches to satisfied lines")
            }
            swapLinesTotal += report.lines.filter(\.viaSwap).count
            if report.lines.contains(where: \.viaSwap) && report.outcome == .complete {
                XCTAssertTrue(report.fitLine.contains("swap"), "seed \(seed + 3_000): swap suffix missing from '\(report.fitLine)'")
            }
        }
        XCTAssertGreaterThan(
            swapLinesTotal, 0,
            "no seed ever produced a swap-attributed line — the attribution property passed vacuously"
        )
    }

    // MARK: Property: determinism under fixed seeds

    func testEvaluationIsDeterministicUnderFixedSeeds() throws {
        for seed in UInt64(1)...10 {
            let scenario = try makeScenario(seed: seed + 4_000)
            var bytes: [Data] = []
            for _ in 0..<2 {
                let report = try FLPantryFeasibility.evaluate(
                    recipe: scenario.recipe,
                    stock: scenario.stock,
                    restriction: scenario.restriction,
                    staples: scenario.staples,
                    swaps: scenario.swaps,
                    targetServings: scenario.targetServings,
                    now: scenario.now,
                    reconfirmWindow: scenario.reconfirmWindow
                )
                bytes.append(try FLJSON.canonicalData(report))
            }
            XCTAssertEqual(bytes[0], bytes[1], "seed \(seed + 4_000): the same inputs must evaluate to byte-identical reports")
        }
    }
}
