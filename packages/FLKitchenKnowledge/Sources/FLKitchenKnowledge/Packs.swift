import Foundation

/// One ingredient line inside a pack. `usdaFdcId` ties the line to a real
/// USDA row so the challenge engine can match recipes; omitted (never guessed)
/// when no plain row exists.
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
    public var notes: String?
}

public struct FoodBankPacksPayload: Codable, Sendable, Equatable {
    public var packs: [FoodBankPack]
}

public struct SeasonalPacksPayload: Codable, Sendable, Equatable {
    public var regions: [SeasonalRegion]
    public var months: [SeasonalMonth]
}

public struct UseItUpPacksPayload: Codable, Sendable, Equatable {
    public var packs: [UseItUpPack]
}

public extension Array where Element == BudgetPack {
    /// Item price sum, for validating a pack against its budget.
    func itemSum(_ pack: BudgetPack) -> Double {
        pack.items.compactMap(\.priceUsd).reduce(0, +)
    }
}
