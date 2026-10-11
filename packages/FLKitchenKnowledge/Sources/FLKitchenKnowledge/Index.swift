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
            learnCardIndex = try JSONDecoder().decode(DataEnvelope<LearnCardIndexPayload>.self, from: indexData).data
        }

        let cardsDirectory = learnCards.appendingPathComponent("cards", isDirectory: true)
        if let cardFiles = try? fileManager.contentsOfDirectory(
            at: cardsDirectory, includingPropertiesForKeys: nil
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var loaded: [LearnCard] = []
            for file in cardFiles where file.pathExtension == "json" {
                guard let data = self.read(file) else { continue }
                loaded.append(try LearnCard.parse(from: data))
            }
            loaded.sort { $0.id < $1.id }
            cards = loaded
            cardsById = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        }

        if let data = self.read(wasteDirectory.appendingPathComponent("emission_factors.json")) {
            let payload = try JSONDecoder().decode(DataEnvelope<EmissionFactorsPayload>.self, from: data).data
            var catalog = waste ?? Self.emptyCatalog
            catalog.emissionByIngredient = Dictionary(
                payload.factors.map { ($0.ingredientKey, $0) },
                uniquingKeysWith: { _, second in second }
            )
            self.waste = catalog
        }
        if let data = self.read(wasteDirectory.appendingPathComponent("price_factors.json")) {
            let payload = try JSONDecoder().decode(DataEnvelope<PriceFactorsPayload>.self, from: data).data
            var catalog = waste ?? Self.emptyCatalog
            catalog.priceByIngredient = Dictionary(
                payload.prices.map { ($0.ingredientKey, $0) },
                uniquingKeysWith: { _, second in second }
            )
            self.waste = catalog
        }
        if let data = self.read(packs.appendingPathComponent("budget_packs.json")) {
            budgetPacks = try JSONDecoder().decode(DataEnvelope<BudgetPacksPayload>.self, from: data).data.packs
        }
        if let data = self.read(packs.appendingPathComponent("food_bank_packs.json")) {
            foodBankPacks = try JSONDecoder().decode(DataEnvelope<FoodBankPacksPayload>.self, from: data).data.packs
        }
        if let data = self.read(packs.appendingPathComponent("seasonal_packs.json")) {
            let payload = try JSONDecoder().decode(DataEnvelope<SeasonalPacksPayload>.self, from: data).data
            seasonalRegions = payload.regions
            seasonalMonths = payload.months
        }
        if let data = self.read(packs.appendingPathComponent("use_it_up_packs.json")) {
            useItUpPacks = try JSONDecoder().decode(DataEnvelope<UseItUpPacksPayload>.self, from: data).data.packs
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
