import Foundation

/// A low / central / high triple. `low` and `high` bracket the uncertainty;
/// a point estimate carries low == central == high.
public struct Range3: Codable, Sendable, Equatable, Hashable {
    public var low: Double
    public var central: Double
    public var high: Double

    public init(low: Double, central: Double, high: Double) {
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
}

/// US dollars per kg, retail weight (BLS Average Price Data / USDA ERS).
public struct PriceFactor: Codable, Sendable, Equatable, Hashable {
    public var ingredientKey: String
    public var usdPerKg: Double
    public var displayQuantity: String?
    public var displayPriceUsd: Double?
    public var sourceSeries: String?
    public var citationId: String
}

/// USDA ERS Loss-Adjusted Food Availability factors, for purchased -> edible
/// translation and display. Never silently multiplied into waste totals: the
/// event stream already observed the outcome.
public struct LossFactor: Codable, Sendable, Equatable, Hashable {
    public var ingredientKey: String
    public var edibleSharePct: Double?
    public var consumerLevelLossPct: Double?
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
    public var grams: Double
    /// Event date, YYYY-MM-DD. Required to evidence a "saved" claim.
    public var on: String?
    /// The lot's use-by date, YYYY-MM-DD, when the lot has one.
    public var lotUseBy: String?

    public init(
        kind: KitchenEventKind, ingredientKey: String, grams: Double,
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
    public var grams: Double
}

public struct WasteBucketTotals: Codable, Sendable, Equatable, Hashable {
    public var grams: Double
    /// Money over the priced grams only; nil when no priced grams fell in this bucket.
    public var moneyUsd: Double?
    public var kgCo2e: Range3?

    public init(grams: Double = 0, moneyUsd: Double? = nil, kgCo2e: Range3? = nil) {
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
    /// Ingredients whose grams were excluded from money/CO2e totals for lack of a
    /// cited factor. Refusals are data, not errors.
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
/// - Rounding at output only (sums computed unrounded): grams 1 decimal,
///   USD 2 decimals, kg CO2e 3 decimals.
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
        if event.grams.isFinite && event.grams > 0 {
            events.append(event)
        } else {
            ignoredEventCount += 1
        }
    }

    /// Non-positive or non-finite gram events are dropped; this counts them.
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
        var gramsByBucket: [WasteBucket: [String: Double]] = [:]
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
            let grams = perIngredient.values.reduce(0, +)
            let isOutcome = bucket != .notCounted

            var money = 0.0
            var anyMoney = false
            var low = 0.0
            var central = 0.0
            var high = 0.0
            var anyCO2 = false

            // Sort keys so float addition order (and therefore the rounded
            // output) is deterministic regardless of dictionary hashing.
            for key in perIngredient.keys.sorted() {
                let gramsForIngredient = perIngredient[key] ?? 0
                let kg = gramsForIngredient / 1000.0
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
            WasteRefusal(
                ingredientKey: $0.ingredientKey, reason: $0.reason,
                grams: Self.round($0.grams, places: rounding.grams)
            )
        }

        return WasteLedgerResult(
            saved: totals(.saved),
            usedLate: totals(.usedLate),
            consumedUnknown: totals(.consumedUnknown),
            wasted: totals(.wasted),
            notCounted: totals(.notCounted),
            refusals: sortedRefusals
        )
    }

    static func round(_ value: Double, places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }
}
