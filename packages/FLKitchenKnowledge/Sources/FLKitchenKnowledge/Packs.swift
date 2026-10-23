import Foundation

/// A quantity authored as a display string ("1 lb") or a bare unit count
/// (1, 0.5). Decodes either, rendering a number as its plain decimal text so
/// nothing is invented and no pack is refused over a display field.
private struct FlexibleQuantityString: Decodable {
    var value: String?

    init(from decoder: Decoder) throws {
        let sc = try decoder.singleValueContainer()
        if let s = try? sc.decode(String.self) {
            value = s
        } else if let n = try? sc.decode(Double.self) {
            value = n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        } else {
            value = nil
        }
    }
}

/// One ingredient line inside a pack. `usdaFdcId` ties the line to a real
/// USDA row so the challenge engine can match recipes; omitted (never guessed)
/// when no plain row exists.
///
/// `quantity` is authored as either a display string ("1 lb") or a bare unit
/// count (1, 0.5). The decoded shape normalizes both to a string — a number
/// renders as its plain decimal text, so nothing is invented and no pack is
/// refused over a display field; `quantityKg` stays the machine-readable mass.
public struct PackItem: Codable, Sendable, Equatable, Hashable {
    public var ingredientKey: String
    public var displayName: String
    public var usdaFdcId: Int?
    public var quantity: String?
    public var quantityKg: Double?
    public var priceUsd: Double?
    public var priceSourceId: String?
    public var typicalForm: String?
    public var citationIds: [String]?
    public var note: String?

    private enum CodingKeys: String, CodingKey {
        case ingredientKey, displayName, usdaFdcId, quantity, quantityKg
        case priceUsd, priceSourceId, typicalForm, citationIds, note
    }

    public init(
        ingredientKey: String, displayName: String, usdaFdcId: Int? = nil,
        quantity: String? = nil, quantityKg: Double? = nil, priceUsd: Double? = nil,
        priceSourceId: String? = nil, typicalForm: String? = nil,
        citationIds: [String]? = nil, note: String? = nil
    ) {
        self.ingredientKey = ingredientKey
        self.displayName = displayName
        self.usdaFdcId = usdaFdcId
        self.quantity = quantity
        self.quantityKg = quantityKg
        self.priceUsd = priceUsd
        self.priceSourceId = priceSourceId
        self.typicalForm = typicalForm
        self.citationIds = citationIds
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ingredientKey = try c.decode(String.self, forKey: .ingredientKey)
        displayName = try c.decode(String.self, forKey: .displayName)
        usdaFdcId = try c.decodeIfPresent(Int.self, forKey: .usdaFdcId)
        quantity = try c.decodeIfPresent(FlexibleQuantityString.self, forKey: .quantity)?.value
        quantityKg = try c.decodeIfPresent(Double.self, forKey: .quantityKg)
        priceUsd = try c.decodeIfPresent(Double.self, forKey: .priceUsd)
        priceSourceId = try c.decodeIfPresent(String.self, forKey: .priceSourceId)
        typicalForm = try c.decodeIfPresent(String.self, forKey: .typicalForm)
        citationIds = try c.decodeIfPresent([String].self, forKey: .citationIds)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ingredientKey, forKey: .ingredientKey)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(usdaFdcId, forKey: .usdaFdcId)
        try c.encodeIfPresent(quantity, forKey: .quantity)
        try c.encodeIfPresent(quantityKg, forKey: .quantityKg)
        try c.encodeIfPresent(priceUsd, forKey: .priceUsd)
        try c.encodeIfPresent(priceSourceId, forKey: .priceSourceId)
        try c.encodeIfPresent(typicalForm, forKey: .typicalForm)
        try c.encodeIfPresent(citationIds, forKey: .citationIds)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

/// A shopping-basket challenge: a set of staples that sums under `budgetUsd`.
public struct BudgetPack: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var budgetUsd: Double
    public var region: String
    /// Month the prices are from, YYYY-MM.
    public var priceDate: String
    public var items: [PackItem]
    public var totalCostUsd: Double?
    public var citationIds: [String]
    public var notes: String?
}

public struct FoodBankPack: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var items: [PackItem]
    public var citationIds: [String]
    public var distributionNote: String?
}

public struct SeasonalRegion: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var definitionCitation: String
}

public struct SeasonalProduce: Codable, Sendable, Equatable, Hashable {
    public var ingredientKey: String
    public var displayName: String
    public var usdaFdcId: Int?
    public var note: String?
}

public struct SeasonalRegionPack: Codable, Sendable, Equatable {
    public var regionId: String
    public var name: String
    public var produce: [SeasonalProduce]
    public var citationIds: [String]
}

public struct SeasonalMonth: Codable, Sendable, Equatable {
    /// 1...12, January first.
    public var month: Int
    public var packs: [SeasonalRegionPack]
}

public struct UseItUpPack: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var situation: String?
    public var ingredients: [PackItem]
    public var tactic: String?
    public var citationIds: [String]
}

// Payloads for the four pack files.

public struct BudgetPacksPayload: Codable, Sendable, Equatable {
    public var packs: [BudgetPack]
    /// The file's source records. Every citationId in the file resolves here;
    /// decoded so provenance survives loading, not just the offline validator.
    public var sources: [SourceRecord]?
    public var notes: String?
}

public struct FoodBankPacksPayload: Codable, Sendable, Equatable {
    public var packs: [FoodBankPack]
    /// The file's source records; see BudgetPacksPayload.sources.
    public var sources: [SourceRecord]?
}

public struct SeasonalPacksPayload: Codable, Sendable, Equatable {
    public var regions: [SeasonalRegion]
    public var months: [SeasonalMonth]
    /// The file's source records; see BudgetPacksPayload.sources.
    public var sources: [SourceRecord]?
}

public struct UseItUpPacksPayload: Codable, Sendable, Equatable {
    public var packs: [UseItUpPack]
    /// The file's source records; see BudgetPacksPayload.sources.
    public var sources: [SourceRecord]?
}

public extension Array where Element == BudgetPack {
    /// Item price sum, for validating a pack against its budget. Nil when any
    /// item lacks a price: the loader refuses such packs, so a loaded
    /// basket's sum is always total, never a silent partial sum.
    func itemSum(_ pack: BudgetPack) -> Double? {
        let prices = pack.items.map(\.priceUsd)
        guard prices.allSatisfy({ $0 != nil }) else { return nil }
        return prices.compactMap { $0 }.reduce(0, +)
    }
}
