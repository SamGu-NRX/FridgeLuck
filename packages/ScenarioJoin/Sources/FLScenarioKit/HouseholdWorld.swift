import Foundation
import FLDomain
import FLPersistence
import FLFlowCore
import FLAssistantCore
import FLInventoryCore
import FLRecipeCore
import FLCommunityCore
import GRDB

// MARK: - Compressed, injectable time
// The scenario week is simulated: every component (ledger events, Tonight,
// cook sessions, the authority) receives `clock.now` explicitly. Nothing in
// this kit calls `Date()` — a rerun replays the same week to the second.

/// A stepped clock over one fixed instant; the scenario advances it.
public struct WeekClock: Sendable {
    public private(set) var now: Date

    public init(startingAt: Date) {
        self.now = startingAt
    }

    public mutating func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    public mutating func advance(minutes: Double) {
        advance(seconds: minutes * 60)
    }

    public mutating func advance(hours: Double) {
        advance(seconds: hours * 3600)
    }

    public mutating func advance(days: Int) {
        advance(seconds: Double(days) * 86_400)
    }

    /// Absolute movement to a scenario timestamp. Must be strictly later —
    /// the clock never runs backwards (see the monotonicity test).
    public mutating func advance(to target: Date) {
        precondition(target > now, "WeekClock cannot run backwards: \(target) is not after \(now)")
        now = target
    }
}

/// The scenario week: Monday 2026-10-05 through Sunday 2026-10-11, UTC
/// (the household's configured zone for the scenario — no wall-clock
/// ambiguity in replay).
public enum Week {
    /// 2026-10-05T00:00:00Z.
    public static let start = Date(timeIntervalSince1970: 1_791_158_400)
    public static let utc: TimeZone = TimeZone(identifier: "UTC")!

    public static func day(_ index: Int, hour: Int, minute: Int = 0) -> Date {
        let base = start.addingTimeInterval(Double(index - 1) * 86_400)
        return base.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
    }

    /// The calendar-day string the share path uses (SPEC 3.4: exact time
    /// beyond the day never leaves the phone).
    public static func dayString(for date: Date) -> String {
        SharedCook.dayString(for: date, timeZone: utc)
    }
}

// MARK: - One household, one store
// The phone's single local write authority: ONE in-memory GRDB database that
// every package migrates by its own namespaced migrations. That all five
// packages' migrations compose onto one store is itself a join assertion —
// a collision in migration IDs or table names fails the world's init.

public final class HouseholdWorld {
    public let db: AppDatabase
    public let householdID: FLHouseholdID
    public let ledger: FLPantryLedger
    public let catalog: FLRecipeCatalog
    public let receiptLedger: GRDBReceiptLedger
    public let revisionClock: AssistantRevisionClock

    /// Deterministic counter for scenario-visible IDs (no randomness).
    public private(set) var idCounter = 0

    public init(household: String = "hh-scenario-1") throws {
        self.householdID = try FLHouseholdID(household)
        self.db = try AppDatabase.inMemory()
        // v1-baseline (FLPersistence), then each sibling's own namespace:
        // v2-flflow-meallog, fl-pantry-v1, fl-recipe-v1, v2-assistant-receipts.
        try db.migrate()
        let flowMigrator = FlowMigrations.migrator()
        try flowMigrator.migrate(db.dbWriter)
        self.ledger = try FLPantryLedger(dbWriter: db.dbWriter, allowedHouseholdID: householdID)
        self.catalog = try FLRecipeCatalog(dbWriter: db.dbWriter)
        self.receiptLedger = try GRDBReceiptLedger(database: db)
        self.revisionClock = try AssistantRevisionClock()
    }

    public func nextID(_ prefix: String) -> String {
        idCounter += 1
        return "\(prefix)-\(String(format: "%04d", idCounter))"
    }

    // MARK: Mapping pantry truth into flow and assistant inputs
    // FLPantryLedger owns stock truth; FLFlowCore's Tonight and
    // FLAssistantCore's snapshots consume plain lines. The join maps without
    // inventing evidence: an item with ANY uncounted lot stays unknown.

    public func stock() throws -> [FLItemStock] {
        try FLStockFold.fold(events: ledger.events(householdID: householdID))
    }

    public func pantryView(now: Date) throws -> PantryView {
        PantryView(lines: try pantryLines(), now: now)
    }

    public func pantryLines() throws -> [FlowPantryLine] {
        try stock().map { item in
            try FlowPantryLine(
                canonicalName: item.ingredient.canonicalName,
                quantity: Self.aggregateEvidence(item),
                lastConfirmedAt: item.lastConfirmedAt,
                source: item.lastConfirmedSource?.rawValue ?? "unknown"
            )
        }
    }

    public func assistantLines() throws -> [AssistantPantryLine] {
        try stock().map { item in
            AssistantPantryLine(
                canonicalName: item.ingredient.canonicalName,
                quantity: Self.aggregateEvidence(item),
                lastConfirmedAt: item.lastConfirmedAt
            )
        }
    }

    /// Honest aggregation: nil when any lot's amount is unknown — a sum that
    /// drops unknown lots would overclaim (SPEC 3.2 "unknown never becomes a
    /// number").
    public static func aggregateEvidence(_ item: FLItemStock) -> QuantityEvidence {
        let lotGrams = item.lots.map { $0.remaining.gramsIfKnown?.grams }
        if lotGrams.isEmpty || lotGrams.contains(where: { $0 == nil }) {
            return .unknown
        }
        let total = lotGrams.compactMap { $0 }.reduce(0, +)
        return (try? GramMass(grams: total)).map { .sourceGrams($0) } ?? .unknown
    }

    /// Reads the week's finished cooks from the meal log (the durable
    /// record the challenge evaluator consumes).
    public func loggedCooks() throws -> [Cook] {
        let payloads = try db.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM flflow_cooks ORDER BY completedAtEpochSeconds, id")
        }
        return try payloads.map { payload in
            try FLJSON.canonicalDecoder().decode(Cook.self, from: Data(payload.utf8))
        }
    }
}

// MARK: - Deterministic fixture builders
// Validated-by-construction domain values for synthetic recipes and stock.
// Everything is fixed: names, IDs, instants. No randomness, no Date().

public enum Fixtures {
    public static func ingredient(_ name: String, fdc: Int? = nil) -> IngredientReference {
        try! IngredientReference(
            fdc: fdc.map { try! FDCIngredientKey(fdcID: $0) },
            localIngredientID: nil,
            canonicalName: name
        )
    }

    public static func grams(_ value: Double) -> QuantityEvidence {
        .sourceGrams(try! GramMass(grams: value))
    }

    /// A recipe line with known grams (`nil` → quantity unknown, honestly).
    public static func line(_ lineID: String, _ name: String, _ grams: Double?, garnish: Bool = false, fdc: Int? = nil) -> IngredientLine {
        try! IngredientLine(
            lineID: lineID,
            ingredient: ingredient(name, fdc: fdc),
            quantity: grams.map { grams_ in .sourceGrams(try! GramMass(grams: grams_)) } ?? .unknown,
            isOptionalGarnish: garnish
        )
    }

    public static func step(_ stepID: String, seconds: Int? = nil) -> Step {
        try! Step(stepID: stepID, action: "Do \(stepID)", durationSeconds: seconds)
    }

    /// A rights-clear license: every offline-relevant right granted, with
    /// recorded evidence (SPEC 3.5).
    public static func clearLicense(_ evidence: String = "scenario: original synthetic recipe authored for this fixture") -> RecipeLicense {
        try! RecipeLicense(
            textRedistribution: .permitted,
            imageRedistribution: .permitted,
            modificationAllowed: .permitted,
            attributionRequired: false,
            cachingAllowed: .permitted,
            offlineUseAllowed: .permitted,
            evidence: evidence
        )
    }

    /// Unknown rights → quarantine (SPEC 3.5) for negative scenarios.
    public static func unknownRightsLicense() -> RecipeLicense {
        try! RecipeLicense(
            textRedistribution: .unknown,
            imageRedistribution: .unknown,
            modificationAllowed: .unknown,
            attributionRequired: false,
            cachingAllowed: .unknown,
            offlineUseAllowed: .unknown,
            evidence: ""
        )
    }

    public static func revision(
        _ sourceRecipeID: String,
        title: String,
        lines: [IngredientLine],
        steps: [Step]? = nil,
        basisServings: Int = 2,
        source: RecipeSource = .catalog,
        license: RecipeLicense? = nil
    ) -> RecipeRevision {
        try! RecipeRevision(
            key: try! RecipeKey(source: source, sourceRecipeID: sourceRecipeID, revision: 1),
            title: title,
            servingBasis: try! ServingBasis(servings: basisServings),
            ingredientLines: lines,
            steps: steps ?? [step("s1"), step("s2"), step("s3")],
            source: RecipeSourceEvidence(origin: source, attribution: nil, license: license ?? clearLicense())
        )
    }

    public static func restriction(
        allergens: Set<Allergen> = [],
        diets: Set<DietExclusion> = [],
        custom: Set<String> = []
    ) -> Restriction {
        try! Restriction(allergens: allergens, dietExclusions: diets, customExclusions: custom)
    }

    // Pantry event builders (scans observe, purchases add — SPEC 3.2).

    public static func purchase(
        _ id: String, _ name: String, grams value: Double?,
        household: FLHouseholdID, command: String, at: Date,
        source: FLStockEventSource = .receipt, fdc: Int? = nil,
        cookID: String? = nil
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .purchase,
            ingredient: ingredient(name, fdc: fdc),
            quantity: value.map { grams($0) } ?? .unknown,
            cookID: cookID,
            source: source,
            timestamp: at
        )
    }

    /// A shelf scan. Observing never adds stock; it reconciles what the scan
    /// saw (a known amount replaces the item's lots with exactly that).
    public static func observation(
        _ id: String, _ name: String, grams value: Double?,
        household: FLHouseholdID, command: String, at: Date,
        fdc: Int? = nil
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .observation,
            ingredient: ingredient(name, fdc: fdc),
            quantity: value.map { grams($0) } ?? .unknown,
            source: .scan,
            timestamp: at
        )
    }

    /// A manual correction superseding a prior event (never erasing it).
    public static func correction(
        _ id: String, _ name: String, grams value: Double?,
        household: FLHouseholdID, command: String, at: Date,
        supersedes prior: String, fdc: Int? = nil
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .correction,
            ingredient: ingredient(name, fdc: fdc),
            quantity: value.map { grams($0) } ?? .unknown,
            source: .manual,
            timestamp: at,
            supersedes: FLStockCorrection(priorEventID: StockEventID(prior), mode: .corrects)
        )
    }

    public static func consumption(
        _ id: String, _ name: String, grams value: Double?,
        household: FLHouseholdID, command: String, at: Date,
        cookID: String? = nil, fdc: Int? = nil
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .consumption,
            ingredient: ingredient(name, fdc: fdc),
            quantity: value.map { grams($0) } ?? .unknown,
            cookID: cookID,
            source: cookID == nil ? .manual : .cook,
            timestamp: at
        )
    }

    public static func spoilage(
        _ id: String, _ name: String, grams value: Double?,
        household: FLHouseholdID, command: String, at: Date,
        fdc: Int? = nil
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .spoilage,
            ingredient: ingredient(name, fdc: fdc),
            quantity: value.map { grams($0) } ?? .unknown,
            source: .manual,
            timestamp: at
        )
    }
}

// MARK: - SPEC 3.1 swap gate
// "Every substitution rechecks all eaters' allergens, including compound
// ingredients." The pantry engine models the swap's effect on feasibility;
// the app-side gate (this pure function) is what the join exercises before a
// swap may be accepted, against each eater's declared allergens.

public enum SwapGate {
    public struct Verdict: Equatable, Sendable {
        public let allowed: Bool
        public let explanation: String
    }

    public static func recheck(
        substitute: IngredientReference,
        substituteAllergens: Set<Allergen>,
        eaterAllergens: [(name: String, allergens: Set<Allergen>)]
    ) -> Verdict {
        for eater in eaterAllergens {
            let clash = substituteAllergens.intersection(eater.allergens)
            if !clash.isEmpty {
                return Verdict(
                    allowed: false,
                    explanation: "swapping in '\(substitute.canonicalName)' is not safe for \(eater.name): \(clash.map { $0.rawValue }.sorted().joined(separator: ", "))"
                )
            }
        }
        return Verdict(
            allowed: true,
            explanation: "swapping in '\(substitute.canonicalName)' rechecked against every eater: no allergen clash"
        )
    }
}

// MARK: - Deterministic household taste signal
// The join's stand-in for the taste engine (FLTaste, PR #115, is a separate
// branch not part of this join): a pure, deterministic score from the
// household's cookCompleted preference history — the exact shape Explore
// needs (a Double per household), never a network or model call.

public enum HouseholdTasteSignal {
    /// Mean cook rating (1...5) scaled to 0...1, +0.05 when the household
    /// would repeat the dish, capped at 1. Cold start → the neutral prior.
    public static func score(events: [PreferenceEvent]) -> Double? {
        let completions = events.filter { $0.kind == .cookCompleted }
        guard !completions.isEmpty else { return nil }
        var total = 0.0
        for event in completions {
            var value = Double(event.rating ?? 3) / 5.0
            if event.wouldRepeat == true { value += 0.05 }
            total += min(value, 1.0)
        }
        return min(total / Double(completions.count), 1.0)
    }
}
