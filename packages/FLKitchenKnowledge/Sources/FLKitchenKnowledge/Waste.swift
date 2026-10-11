import Foundation

/// A low / central / high triple. `low` and `high` bracket the uncertainty;
/// a point estimate carries low == central == high.
///
/// Arithmetic on factors uses `Decimal` throughout: the model binds half-up
/// rounding applied to the *decimal representation* of the factor values
/// (data/kitchen-knowledge/waste/model.md §4), which binary floating-point
/// misrounds on ties (0.25 x 9.87 = 2.4675 must round to 2.468, and
/// 6.25 x 3.15 = 19.6875 to 19.688; ex-18 and ex-19 bind this).
public struct Range3: Codable, Sendable, Equatable, Hashable {
    public var low: Decimal
    public var central: Decimal
    public var high: Decimal

    public init(low: Decimal, central: Decimal, high: Decimal) {
        self.low = low
        self.central = central
        self.high = high
    }
}

/// kg CO2e per kg of food, land-to-retail (Poore & Nemecek 2018 via Our World in Data).
public struct EmissionFactor: Codable, Sendable, Equatable, Hashable {
    public var ingredientKey: String
    public var owidEntity: String?
    public var kgCo2ePerKg: Range3
    public var citationId: String

    public init(ingredientKey: String, owidEntity: String?, kgCo2ePerKg: Range3, citationId: String) {
        self.ingredientKey = ingredientKey
        self.owidEntity = owidEntity
        self.kgCo2ePerKg = kgCo2ePerKg
        self.citationId = citationId
    }
}

/// US dollars per kg, retail weight (BLS Average Price Data / USDA ERS).
public struct PriceFactor: Codable, Sendable, Equatable, Hashable {
    public var ingredientKey: String
    public var usdPerKg: Decimal
    public var displayQuantity: String?
    public var displayPriceUsd: Decimal?
    public var sourceSeries: String?
    public var citationId: String

    public init(
        ingredientKey: String, usdPerKg: Decimal, displayQuantity: String?,
        displayPriceUsd: Decimal?, sourceSeries: String?, citationId: String
    ) {
        self.ingredientKey = ingredientKey
        self.usdPerKg = usdPerKg
        self.displayQuantity = displayQuantity
        self.displayPriceUsd = displayPriceUsd
        self.sourceSeries = sourceSeries
        self.citationId = citationId
    }
}

/// USDA ERS Loss-Adjusted Food Availability factors, for purchased -> edible
/// translation and display. Never silently multiplied into waste totals: the
/// event stream already observed the outcome (model.md §7). Percentages are
/// Decimal for uniform factor decoding; they never enter ledger arithmetic.
public struct LossFactor: Codable, Sendable, Equatable, Hashable {
    public var ingredientKey: String
    public var edibleSharePct: Decimal?
    public var consumerLevelLossPct: Decimal?
    public var note: String?
    public var citationId: String
}

/// The event kinds the app's inventory writes (`InventoryEvent.eventType` on alpha).
public enum KitchenEventKind: String, Codable, Sendable, Equatable {
    case add
    case consume
    case adjust
    case discard
    case expire
}

/// One inventory event, normalized to positive grams.
///
/// Dates are ISO `YYYY-MM-DD` strings; the ledger compares them
/// lexicographically, which is correct for zero-padded ISO dates.
public struct KitchenEvent: Codable, Sendable, Equatable {
    public var kind: KitchenEventKind
    public var ingredientKey: String
    public var grams: Decimal
    /// Event date, YYYY-MM-DD. Required to evidence a "saved" claim.
    public var on: String?
    /// The lot's use-by date, YYYY-MM-DD, when the lot has one.
    public var lotUseBy: String?

    public init(
        kind: KitchenEventKind, ingredientKey: String, grams: Decimal,
        on: String? = nil, lotUseBy: String? = nil
    ) {
        self.kind = kind
        self.ingredientKey = ingredientKey
        self.grams = grams
        self.on = on
        self.lotUseBy = lotUseBy
    }
}

public enum WasteBucket: String, Codable, Sendable, Equatable, CaseIterable {
    /// Consumed on or before the lot's use-by date. The only bucket a
    /// "food saved" claim may count.
    case saved
    /// Consumed after the use-by date: food was eaten, but the copy rule
    /// forbids claiming it as saved.
    case usedLate
    /// Consumed with no lot use-by or no event date: cannot evidence
    /// "before use-by", so excluded from saved claims.
    case consumedUnknown
    /// Discarded or expired.
    case wasted
    /// add/adjust: inventory corrections, not food outcomes.
    case notCounted
}

public struct WasteRefusal: Codable, Sendable, Equatable, Hashable {
    public enum Reason: String, Codable, Sendable, Equatable {
        case missingPrice
        case missingEmissionFactor
    }

    public var ingredientKey: String
    public var reason: Reason
    public var grams: Decimal
}

public struct WasteBucketTotals: Codable, Sendable, Equatable, Hashable {
    public var grams: Decimal
    /// Money over the priced grams only; nil when no priced grams fell in this bucket.
    public var moneyUsd: Decimal?
    public var kgCo2e: Range3?

    public init(grams: Decimal = 0, moneyUsd: Decimal? = nil, kgCo2e: Range3? = nil) {
        self.grams = grams
        self.moneyUsd = moneyUsd
        self.kgCo2e = kgCo2e
    }
}

public struct WasteLedgerResult: Codable, Sendable, Equatable {
    public var saved: WasteBucketTotals
    public var usedLate: WasteBucketTotals
    public var consumedUnknown: WasteBucketTotals
    public var wasted: WasteBucketTotals
    public var notCounted: WasteBucketTotals
    /// The refusal shape the model binds (model.md §5–6): per reason, the
    /// refused ingredient keys and the grams excluded from that factor's
    /// totals. Grams are summed unrounded across ingredients and rounded
    /// once for output, matching the bucket totals' discipline.
    public var unpricedIngredientKeys: [String]
    public var unpricedGrams: Decimal
    public var missingEmissionFactorKeys: [String]
    public var missingEmissionFactorGrams: Decimal
    /// Per-(ingredient, reason) detail behind the two totals above. Grams are
    /// the UNROUNDED aggregates — round once at display. Rounding a row
    /// before summing loses the tail (100.04 g + 200.04 g must report
    /// 300.1 g, not 300.0 g); the binding totals above are the canonical
    /// outputs.
    public var refusals: [WasteRefusal]
}

/// The waste accounting engine.
///
/// Semantics (data/kitchen-knowledge/waste/model.md binds the detail):
/// - Buckets: consume on/before use-by = saved; consume after = usedLate;
///   consume with unknown evidence = consumedUnknown; discard/expire = wasted;
///   add/adjust = notCounted. Use-by dates are inclusive (same-day counts as saved).
/// - Money: kg x usdPerKg, a point value; no price uncertainty is claimed.
/// - Emissions: kg x kgCo2ePerKg, low/central/high propagated linearly.
/// - Decimal arithmetic on the factor representations; rounding at output
///   only (sums computed unrounded), half-up (ties away from zero):
///   grams 1 decimal, USD 2 decimals, kg CO2e 3 decimals.
/// - Refusal: grams without a cited price or emission factor are excluded from
///   the money/CO2e totals and reported in `refusals`; they are never guessed.
public struct WasteLedger {
    public struct Rounding: Sendable, Equatable {
        public var grams: Int
        public var moneyUsd: Int
        public var kgCo2e: Int

        public init(grams: Int, moneyUsd: Int, kgCo2e: Int) {
            self.grams = grams
            self.moneyUsd = moneyUsd
            self.kgCo2e = kgCo2e
        }

        /// The rounding data/kitchen-knowledge/waste binds.
        public static let standard = Rounding(grams: 1, moneyUsd: 2, kgCo2e: 3)
    }

    public var rounding: Rounding

    private var events: [KitchenEvent] = []
    private var ignoredEventCount = 0
    private var prices: [String: PriceFactor] = [:]
    private var emissions: [String: EmissionFactor] = [:]

    public init(
        prices: [PriceFactor] = [], emissions: [EmissionFactor] = [],
        rounding: Rounding = .standard
    ) {
        self.rounding = rounding
        for price in prices { self.prices[price.ingredientKey] = price }
        for emission in emissions { self.emissions[emission.ingredientKey] = emission }
    }

    public mutating func record(_ event: KitchenEvent) {
        // Decimal values are always finite; non-positive gram events are dropped.
        if event.grams > 0 {
            events.append(event)
        } else {
            ignoredEventCount += 1
        }
    }

    /// Non-positive gram events are dropped; this counts them.
    public var droppedEventCount: Int { ignoredEventCount }

    /// Buckets the event stream observed, ignoring inventory corrections.
    static func bucket(for event: KitchenEvent) -> WasteBucket {
        switch event.kind {
        case .add, .adjust:
            return .notCounted
        case .discard, .expire:
            return .wasted
        case .consume:
            guard let useBy = event.lotUseBy, let on = event.on else {
                return .consumedUnknown
            }
            // Inclusive use-by: same-day consumption still counts as saved.
            return on <= useBy ? .saved : .usedLate
        }
    }

    public func result() -> WasteLedgerResult {
        var gramsByBucket: [WasteBucket: [String: Decimal]] = [:]
        for event in events {
            let bucket = Self.bucket(for: event)
            gramsByBucket[bucket, default: [:]][event.ingredientKey, default: 0] += event.grams
        }

        let outcomeBuckets: [WasteBucket] = [.saved, .usedLate, .consumedUnknown, .wasted]

        // Refusals aggregate (ingredient, reason) across the outcome buckets.
        var refusalGrams: [String: WasteRefusal] = [:]
        for bucket in outcomeBuckets {
            for (key, grams) in gramsByBucket[bucket] ?? [:] {
                if prices[key] == nil {
                    let id = key + "|missingPrice"
                    refusalGrams[id, default: WasteRefusal(ingredientKey: key, reason: .missingPrice, grams: 0)].grams += grams
                }
                if emissions[key] == nil {
                    let id = key + "|missingEmissionFactor"
                    refusalGrams[id, default: WasteRefusal(ingredientKey: key, reason: .missingEmissionFactor, grams: 0)].grams += grams
                }
            }
        }

        func totals(_ bucket: WasteBucket) -> WasteBucketTotals {
            let perIngredient = gramsByBucket[bucket] ?? [:]
            var grams: Decimal = 0
            for value in perIngredient.values { grams += value }
            let isOutcome = bucket != .notCounted

            var money: Decimal = 0
            var anyMoney = false
            var low: Decimal = 0
            var central: Decimal = 0
            var high: Decimal = 0
            var anyCO2 = false

            // Sort keys so decimal addition order — and therefore the rounded
            // output — is deterministic regardless of dictionary hashing.
            for key in perIngredient.keys.sorted() {
                let gramsForIngredient = perIngredient[key] ?? 0
                let kg = gramsForIngredient / 1000
                if isOutcome, let price = prices[key] {
                    money += kg * price.usdPerKg
                    anyMoney = true
                }
                if isOutcome, let emission = emissions[key] {
                    low += kg * emission.kgCo2ePerKg.low
                    central += kg * emission.kgCo2ePerKg.central
                    high += kg * emission.kgCo2ePerKg.high
                    anyCO2 = true
                }
            }

            return WasteBucketTotals(
                grams: Self.round(grams, places: rounding.grams),
                moneyUsd: anyMoney ? Self.round(money, places: rounding.moneyUsd) : nil,
                kgCo2e: anyCO2
                    ? Range3(
                        low: Self.round(low, places: rounding.kgCo2e),
                        central: Self.round(central, places: rounding.kgCo2e),
                        high: Self.round(high, places: rounding.kgCo2e)
                    )
                    : nil
            )
        }

        let sortedRefusals = refusalGrams.values.sorted {
            ($0.ingredientKey, $0.reason.rawValue) < ($1.ingredientKey, $1.reason.rawValue)
        }.map {
            // Row detail stays unrounded; the binding totals below round once.
            WasteRefusal(ingredientKey: $0.ingredientKey, reason: $0.reason, grams: $0.grams)
        }

        func refusalTotal(_ reason: WasteRefusal.Reason) -> (keys: [String], grams: Decimal) {
            let rows = refusalGrams.values.filter { $0.reason == reason }
            let grams = rows.map(\.grams).reduce(0, +)
            return (rows.map(\.ingredientKey).sorted(), Self.round(grams, places: rounding.grams))
        }
        let unpriced = refusalTotal(.missingPrice)
        let missingEmission = refusalTotal(.missingEmissionFactor)

        return WasteLedgerResult(
            saved: totals(.saved),
            usedLate: totals(.usedLate),
            consumedUnknown: totals(.consumedUnknown),
            wasted: totals(.wasted),
            notCounted: totals(.notCounted),
            unpricedIngredientKeys: unpriced.keys,
            unpricedGrams: unpriced.grams,
            missingEmissionFactorKeys: missingEmission.keys,
            missingEmissionFactorGrams: missingEmission.grams,
            refusals: sortedRefusals
        )
    }

    /// Half-up (ties away from zero) decimal rounding to `places` digits,
    /// per model.md §4. NSDecimalRound(.plain) is round-half-away-from-zero.
    static func round(_ value: Decimal, places: Int) -> Decimal {
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, places, .plain)
        return rounded
    }
}
