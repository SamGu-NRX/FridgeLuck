import Foundation

// Payload shapes for the waste factor files.

/// The file-level citation block of a factor table (`data.source`). Describes
/// where the table came from; factor rows point back to it via their
/// `citationId`. Unlike a learn card's keyed `SourceRecord`, a table citation
/// carries no per-row id — and its exact optional descriptors (secondaryUrl,
/// retrievedVia, …) vary per table, so unknown keys decode-and-ignore.
public struct TableCitation: Codable, Sendable, Equatable, Hashable {
    public var citationId: String
    public var title: String
    public var publisher: String
    public var url: String
}

public struct EmissionFactorsPayload: Codable, Sendable, Equatable {
    public var source: TableCitation?
    public var method: String?
    public var factors: [EmissionFactor]
}

public struct PriceFactorsPayload: Codable, Sendable, Equatable {
    public var source: TableCitation?
    public var region: String?
    public var asOf: String?
    public var method: String?
    public var prices: [PriceFactor]
}

/// The two waste factor tables, keyed for lookup.
public struct WasteCatalog: Sendable, Equatable {
    public var emissionByIngredient: [String: EmissionFactor]
    public var priceByIngredient: [String: PriceFactor]

    public init(
        emissionByIngredient: [String: EmissionFactor] = [:],
        priceByIngredient: [String: PriceFactor] = [:]
    ) {
        self.emissionByIngredient = emissionByIngredient
        self.priceByIngredient = priceByIngredient
    }

    public func emission(for ingredientKey: String) -> EmissionFactor? {
        emissionByIngredient[ingredientKey]
    }

    public func price(for ingredientKey: String) -> PriceFactor? {
        priceByIngredient[ingredientKey]
    }
}

/// Loads data/kitchen-knowledge/ and exposes lookups over it.
///
/// Loading is tolerant of a data directory still being assembled (a sub-branch
/// not yet joined): whatever is present loads, whatever is absent stays nil.
/// Files that are present but fail their shape contract or source validation
/// throw, rather than loading half-sourced data.
public struct KitchenKnowledge: Sendable {
    public private(set) var cards: [LearnCard] = []
    public private(set) var learnCardIndex: LearnCardIndexPayload?
    public private(set) var waste: WasteCatalog?
    public private(set) var budgetPacks: [BudgetPack] = []
    public private(set) var foodBankPacks: [FoodBankPack] = []
    public private(set) var seasonalRegions: [SeasonalRegion] = []
    public private(set) var seasonalMonths: [SeasonalMonth] = []
    public private(set) var useItUpPacks: [UseItUpPack] = []
    /// Each pack file's `sources` records, keyed by file stem. The pack files'
    /// provenance: every citationId in a pack file must resolve here.
    public private(set) var packSourcesByFile: [String: [SourceRecord]] = [:]

    private var cardsById: [String: LearnCard] = [:]

    public init(directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            throw MissingSourceError(subject: "kitchen-knowledge", reason: "directory \(directory.path) does not exist")
        }

        let learnCards = directory.appendingPathComponent("learn-cards", isDirectory: true)
        let wasteDirectory = directory.appendingPathComponent("waste", isDirectory: true)
        let packs = directory.appendingPathComponent("packs", isDirectory: true)

        if let indexData = self.read(learnCards.appendingPathComponent("index.json")) {
            learnCardIndex = try DataEnvelope<LearnCardIndexPayload>
                .decode(indexData, expectingKind: "learn-card-index").data
        }

        let cardsDirectory = learnCards.appendingPathComponent("cards", isDirectory: true)
        if let cardFiles = try? fileManager.contentsOfDirectory(
            at: cardsDirectory, includingPropertiesForKeys: nil
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var loaded: [LearnCard] = []
            var seenCardIds = Set<String>()
            for file in cardFiles where file.pathExtension == "json" {
                guard let data = self.read(file) else { continue }
                let card = try LearnCard.parse(from: data)
                guard seenCardIds.insert(card.id).inserted else {
                    throw DuplicateIdError(subject: "learn-cards/cards/*.json", id: card.id)
                }
                loaded.append(card)
            }
            loaded.sort { $0.id < $1.id }
            cards = loaded
            cardsById = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        }

        // The index mirrors the cards, not an independent opinion: id sets
        // must agree both ways, and a nutrition fdcId must match its mirror.
        if let index = learnCardIndex {
            try Self.requireUniqueIds(index.cards.map(\.id), subject: "learn-cards/index.json")
            for entry in index.cards {
                guard let card = cardsById[entry.id] else {
                    throw MissingSourceError(
                        subject: "learn-cards/index.json",
                        reason: "index lists card '\(entry.id)' with no card file"
                    )
                }
                let cardFdcId = card.nutritionPer100g?.fdcId
                guard entry.fdcId == cardFdcId else {
                    throw MissingSourceError(
                        subject: "learn-cards/index.json",
                        reason: "card '\(entry.id)' nutrition fdcId "
                            + "\(cardFdcId.map(String.init) ?? "none") disagrees "
                            + "with the index (\(entry.fdcId.map(String.init) ?? "none"))"
                    )
                }
            }
            for card in cards where !index.cards.contains(where: { $0.id == card.id }) {
                throw MissingSourceError(
                    subject: "learn-cards/index.json",
                    reason: "card '\(card.id)' exists but is not listed in the index"
                )
            }
        }

        if let data = self.read(wasteDirectory.appendingPathComponent("emission_factors.json")) {
            let payload = try DataEnvelope<EmissionFactorsPayload>
                .decode(data, expectingKind: "emission-factors").data
            try Self.validateFactorRows(
                payload.factors.map(\.citationId), table: payload.source?.citationId,
                subject: "waste/emission_factors.json"
            )
            try Self.validateEmissionNumerics(
                payload.factors, subject: "waste/emission_factors.json"
            )
            var catalog = waste ?? Self.emptyCatalog
            catalog.emissionByIngredient = try Self.uniqueDictionary(
                payload.factors.map { ($0.ingredientKey, $0) },
                subject: "waste/emission_factors.json"
            )
            self.waste = catalog
        }
        if let data = self.read(wasteDirectory.appendingPathComponent("price_factors.json")) {
            let payload = try DataEnvelope<PriceFactorsPayload>
                .decode(data, expectingKind: "price-factors").data
            try Self.validateFactorRows(
                payload.prices.map(\.citationId), table: payload.source?.citationId,
                subject: "waste/price_factors.json"
            )
            try Self.validatePriceNumerics(
                payload.prices, subject: "waste/price_factors.json"
            )
            var catalog = waste ?? Self.emptyCatalog
            catalog.priceByIngredient = try Self.uniqueDictionary(
                payload.prices.map { ($0.ingredientKey, $0) },
                subject: "waste/price_factors.json"
            )
            self.waste = catalog
        }
        if let data = self.read(packs.appendingPathComponent("budget_packs.json")) {
            let payload = try DataEnvelope<BudgetPacksPayload>
                .decode(data, expectingKind: "budget-packs").data
            try Self.validatePackCitations(
                packs: payload.packs.map {
                    PackCitationInputs(id: $0.id, items: $0.items, citationIds: $0.citationIds)
                },
                sources: payload.sources ?? [],
                subject: "packs/budget_packs.json"
            )
            try Self.validateBudgetNumerics(
                payload.packs, subject: "packs/budget_packs.json"
            )
            budgetPacks = payload.packs
            packSourcesByFile["budget_packs"] = payload.sources ?? []
        }
        if let data = self.read(packs.appendingPathComponent("food_bank_packs.json")) {
            let payload = try DataEnvelope<FoodBankPacksPayload>
                .decode(data, expectingKind: "food-bank-packs").data
            try Self.validatePackCitations(
                packs: payload.packs.map {
                    PackCitationInputs(id: $0.id, items: $0.items, citationIds: $0.citationIds)
                },
                sources: payload.sources ?? [],
                subject: "packs/food_bank_packs.json"
            )
            try Self.validateUnbudgetedItemNumerics(
                payload.packs.flatMap(\.items), subject: "packs/food_bank_packs.json"
            )
            foodBankPacks = payload.packs
            packSourcesByFile["food_bank_packs"] = payload.sources ?? []
        }
        if let data = self.read(packs.appendingPathComponent("seasonal_packs.json")) {
            let payload = try DataEnvelope<SeasonalPacksPayload>
                .decode(data, expectingKind: "seasonal-packs").data
            try Self.validateSeasonal(
                payload, subject: "packs/seasonal_packs.json"
            )
            seasonalRegions = payload.regions
            seasonalMonths = payload.months
            packSourcesByFile["seasonal_packs"] = payload.sources ?? []
        }
        if let data = self.read(packs.appendingPathComponent("use_it_up_packs.json")) {
            let payload = try DataEnvelope<UseItUpPacksPayload>
                .decode(data, expectingKind: "use-it-up-packs").data
            try Self.validatePackCitations(
                packs: payload.packs.map {
                    PackCitationInputs(id: $0.id, items: $0.ingredients, citationIds: $0.citationIds)
                },
                sources: payload.sources ?? [],
                subject: "packs/use_it_up_packs.json"
            )
            try Self.validateUnbudgetedItemNumerics(
                payload.packs.flatMap(\.ingredients), subject: "packs/use_it_up_packs.json"
            )
            useItUpPacks = payload.packs
            packSourcesByFile["use_it_up_packs"] = payload.sources ?? []
        }
    }

    // MARK: - Loader contract

    /// Ids in a file must be unique; a duplicate throws rather than silently
    /// keeping one record.
    private static func requireUniqueIds(_ ids: [String], subject: String) throws {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted {
            throw DuplicateIdError(subject: subject, id: id)
        }
    }

    /// Every citation id used in a file must resolve to a source record in
    /// that same file.
    private static func requireResolvable(
        _ usedIds: [String], in knownIds: Set<String>, subject: String
    ) throws {
        for id in usedIds where !knownIds.contains(id) {
            throw MissingSourceError(
                subject: subject,
                reason: "citation '\(id)' has no source record in the file"
            )
        }
    }

    /// Waste factor rows may only cite the file's own table citation.
    private static func validateFactorRows(
        _ rowCitationIds: [String], table: String?, subject: String
    ) throws {
        guard let table else {
            guard rowCitationIds.isEmpty else {
                throw MissingSourceError(
                    subject: subject,
                    reason: "factor rows cite sources but the file has no table citation"
                )
            }
            return
        }
        try requireResolvable(rowCitationIds, in: Set([table]), subject: subject)
    }

    /// Pack files: unique pack ids, unique source-record ids, and every
    /// citation (pack-level, item-level, priceSourceId) resolving in the
    /// file's own `sources` list.
    private static func validatePackCitations(
        packs: [PackCitationInputs], sources: [SourceRecord], subject: String
    ) throws {
        try requireUniqueIds(packs.map(\.id), subject: "\(subject) pack ids")
        try requireUniqueIds(sources.map(\.id), subject: "\(subject) source records")
        let known = Set(sources.map(\.id))
        let used = packs.flatMap { pack -> [String] in
            pack.citationIds
                + pack.items.flatMap { ($0.citationIds ?? []) + [$0.priceSourceId].compactMap { $0 } }
        }
        try requireResolvable(used, in: known, subject: subject)
    }

    /// The id/item/citation shape the pack validator needs, extracted at the
    /// call site (use-it-up packs name their item list `ingredients`).
    private struct PackCitationInputs {
        var id: String
        var items: [PackItem]
        var citationIds: [String]
    }

    // MARK: - Numeric contract

    /// Plausibility caps mirroring the offline waste validator: impossibility
    /// filters, not advice. No credible per-kg food inventory exceeds 150
    /// kgCO2e/kg (shipped max 99.48); a grocery staple above 1500 USD/kg is a
    /// decimal or unit slip (shipped max 15.97).
    private static let emissionCapKgCo2ePerKg: Decimal = 150
    private static let priceCapUsdPerKg: Decimal = 1500

    /// Impossible numbers refuse to load (SCHEMA.md, "Numeric contract"):
    /// negative or non-finite money, non-positive masses, misordered ranges.
    /// An omitted value (a use-it-up item carries no price) stays nil — a
    /// present value must still be physically possible.

    private static func validateItemNumerics(
        _ item: PackItem, subject: String, requirePositivePrice: Bool
    ) throws {
        if let kg = item.quantityKg {
            guard kg.isFinite, kg > 0 else {
                throw InvalidNumericError(
                    subject: subject, field: "\(item.ingredientKey).quantityKg",
                    value: "\(kg)", reason: "a mass must be finite and positive"
                )
            }
        }
        if let price = item.priceUsd {
            guard price.isFinite, requirePositivePrice ? price > 0 : price >= 0 else {
                throw InvalidNumericError(
                    subject: subject, field: "\(item.ingredientKey).priceUsd",
                    value: "\(price)",
                    reason: requirePositivePrice
                        ? "a budget item's price must be a positive amount"
                        : "a price must be a finite non-negative amount"
                )
            }
        }
    }

    private static func validateBudgetNumerics(_ packs: [BudgetPack], subject: String) throws {
        for pack in packs {
            guard pack.budgetUsd.isFinite, pack.budgetUsd >= 0 else {
                throw InvalidNumericError(
                    subject: subject, field: "\(pack.id).budgetUsd",
                    value: "\(pack.budgetUsd)",
                    reason: "a budget must be a finite non-negative amount"
                )
            }
            // A budget basket is priced and weighed line by line: a missing
            // value must refuse, never silently shrink the sum.
            var total: Double = 0
            for item in pack.items {
                guard let price = item.priceUsd, item.quantityKg != nil else {
                    throw InvalidNumericError(
                        subject: "\(subject)/\(pack.id)",
                        field: item.priceUsd == nil
                            ? "\(item.ingredientKey).priceUsd"
                            : "\(item.ingredientKey).quantityKg",
                        value: "missing",
                        reason: "a budget item must carry a positive price and a positive mass"
                    )
                }
                try validateItemNumerics(
                    item, subject: "\(subject)/\(pack.id)", requirePositivePrice: true
                )
                total += price
            }
            // Round once, like the offline validator, then compare.
            total = (total * 10000).rounded() / 10000
            if let stated = pack.totalCostUsd, abs(total - stated) > 0.0005 {
                throw InvalidNumericError(
                    subject: subject, field: "\(pack.id).totalCostUsd",
                    value: "\(stated)",
                    reason: "stated total does not match the item sum \(total)"
                )
            }
            guard total <= pack.budgetUsd + 1e-9 else {
                throw InvalidNumericError(
                    subject: subject, field: "\(pack.id).items",
                    value: "sum \(total)",
                    reason: "item prices exceed the stated budget \(pack.budgetUsd)"
                )
            }
        }
    }

    private static func validateUnbudgetedItemNumerics(
        _ items: [PackItem], subject: String
    ) throws {
        for item in items {
            try validateItemNumerics(item, subject: subject, requirePositivePrice: false)
        }
    }

    private static func validateEmissionNumerics(
        _ factors: [EmissionFactor], subject: String
    ) throws {
        for factor in factors {
            let range = factor.kgCo2ePerKg
            for (end, value) in [("low", range.low), ("central", range.central), ("high", range.high)] {
                guard value >= 0 else {
                    throw InvalidNumericError(
                        subject: subject,
                        field: "\(factor.ingredientKey).kgCo2ePerKg.\(end)",
                        value: "\(value)", reason: "an emission factor must be non-negative"
                    )
                }
                guard value <= Self.emissionCapKgCo2ePerKg else {
                    throw InvalidNumericError(
                        subject: subject,
                        field: "\(factor.ingredientKey).kgCo2ePerKg.\(end)",
                        value: "\(value)",
                        reason: "an emission factor is implausibly large "
                            + "(cap \(Self.emissionCapKgCo2ePerKg))"
                    )
                }
            }
            guard range.low <= range.central, range.central <= range.high else {
                throw InvalidNumericError(
                    subject: subject, field: "\(factor.ingredientKey).kgCo2ePerKg",
                    value: "low \(range.low), central \(range.central), high \(range.high)",
                    reason: "a range must satisfy low <= central <= high"
                )
            }
        }
    }

    private static func validatePriceNumerics(_ prices: [PriceFactor], subject: String) throws {
        for price in prices {
            // Decimal cannot carry NaN or infinity; a negative rate is the
            // failure mode to refuse.
            guard price.usdPerKg >= 0 else {
                throw InvalidNumericError(
                    subject: subject, field: "\(price.ingredientKey).usdPerKg",
                    value: "\(price.usdPerKg)", reason: "a price must be non-negative"
                )
            }
            guard price.usdPerKg <= Self.priceCapUsdPerKg else {
                throw InvalidNumericError(
                    subject: subject, field: "\(price.ingredientKey).usdPerKg",
                    value: "\(price.usdPerKg)",
                    reason: "a price is implausibly large (cap \(Self.priceCapUsdPerKg))"
                )
            }
            if let display = price.displayPriceUsd, display < 0 {
                throw InvalidNumericError(
                    subject: subject, field: "\(price.ingredientKey).displayPriceUsd",
                    value: "\(display)", reason: "a price must be non-negative"
                )
            }
        }
    }

    /// Waste factor rows may only cite the file's own table citation; keys
    /// must be unique so lookups cannot silently lose a row.
    private static func uniqueDictionary<Value>(
        _ pairs: [(String, Value)], subject: String
    ) throws -> [String: Value] {
        var result: [String: Value] = [:]
        for (key, value) in pairs {
            guard result[key] == nil else {
                throw DuplicateIdError(subject: subject, id: key, reason: "ingredient key appears twice")
            }
            result[key] = value
        }
        return result
    }

    /// Seasonal files: unique region ids, unique months in 1...12, month
    /// packs referencing declared regions, and citations resolving in the
    /// file's own sources.
    private static func validateSeasonal(_ payload: SeasonalPacksPayload, subject: String) throws {
        try requireUniqueIds(payload.regions.map(\.id), subject: "\(subject) region ids")
        try requireUniqueIds((payload.sources ?? []).map(\.id), subject: "\(subject) source records")

        var seenMonths = Set<Int>()
        for month in payload.months {
            guard (1...12).contains(month.month), seenMonths.insert(month.month).inserted else {
                throw DuplicateIdError(
                    subject: "\(subject) months", id: String(month.month),
                    reason: "months must be unique and within 1...12"
                )
            }
        }

        let regionIds = Set(payload.regions.map(\.id))
        let used: [String] = payload.regions.map(\.definitionCitation)
            + payload.months.flatMap { month in
                month.packs.flatMap { [$0.regionId] + $0.citationIds }
            }
        try requireResolvable(used.filter { !regionIds.contains($0) }, in: Set((payload.sources ?? []).map(\.id)), subject: subject)

        for month in payload.months {
            for pack in month.packs where !regionIds.contains(pack.regionId) {
                throw MissingSourceError(
                    subject: subject,
                    reason: "month \(month.month) pack references region '\(pack.regionId)' with no region record"
                )
            }
        }
    }



    private static let emptyCatalog = WasteCatalog()

    public func card(id: String) -> LearnCard? { cardsById[id] }

    public func cardsInCategory(_ category: String) -> [LearnCard] {
        cards.filter { $0.category == category }
    }

    public func cards(named substring: String) -> [LearnCard] {
        cards.filter { $0.displayName.localizedCaseInsensitiveContains(substring) }
    }

    /// Every distinct source record across the pack files' `sources` lists.
    public func allPackSources() -> [SourceRecord] {
        var seen: [String: SourceRecord] = [:]
        for file in packSourcesByFile.keys.sorted() {
            for source in packSourcesByFile[file] ?? [] {
                let key = "\(source.url)|\(source.title)|\(source.publisher)"
                if seen[key] == nil { seen[key] = source }
            }
        }
        return seen.values.sorted { $0.id < $1.id }
    }

    /// Every distinct source record across all loaded cards.
    public func allSources() -> [SourceRecord] {
        var seen: [String: SourceRecord] = [:]
        for card in cards {
            for (id, source) in card.sources {
                let key = "\(source.url)|\(source.title)|\(source.publisher)"
                if seen[key] == nil {
                    seen[key] = SourceRecord(
                        id: id, title: source.title, publisher: source.publisher,
                        url: source.url, retrieved: source.retrieved,
                        licence: source.licence, notes: source.notes
                    )
                }
            }
        }
        return seen.values.sorted { $0.id < $1.id }
    }

    private func read(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: url.path)
    }
}

