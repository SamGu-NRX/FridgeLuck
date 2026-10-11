import Foundation

/// Where storage and shelf-life guidance lives: the food-safety rulebook owns it
/// (data/food-safety, PR #97); learn cards link to it rather than restating it.
public struct FoodSafetyRef: Codable, Sendable, Equatable, Hashable {
    public var path: String
    public var note: String?
}

public struct CitedSection: Codable, Sendable, Equatable, Hashable {
    public var text: String
    public var citations: [String]
    public var foodSafetyRef: FoodSafetyRef?
}

public struct Substitution: Codable, Sendable, Equatable, Hashable {
    public var substitute: String
    public var ratio: String?
    public var note: String?
    public var citations: [String]
}

/// Per-100 g nutrient vector; a field is nil exactly when the cited
/// FoodData Central row has no value for it. Never a fabricated zero.
public struct NutritionVector: Codable, Sendable, Equatable, Hashable {
    public var energyKcal: Double?
    public var proteinG: Double?
    public var carbohydrateG: Double?
    public var sugarG: Double?
    public var fiberG: Double?
    public var fatG: Double?
    public var saturatedFatG: Double?
    public var sodiumMg: Double?
    public var potassiumMg: Double?
    public var calciumMg: Double?
    public var ironMg: Double?
    public var vitaminCMg: Double?
    public var vitaminARaeMcg: Double?
    public var folateMcg: Double?
}

public struct NutritionPer100g: Codable, Sendable, Equatable, Hashable {
    /// The FoodData Central row the numbers were pulled from.
    public var fdcId: Int
    public var fdcDescription: String
    public var fdcDataType: String
    /// Must resolve in the card's `sources` map.
    public var sourceId: String
    public var nutrients: NutritionVector
}

public extension NutritionVector {
    /// Every present value as (field, value, plausible per-100 g range).
    ///
    /// The caps are impossibility filters, not nutrition advice
    /// (data/kitchen-knowledge/SCHEMA.md, "Numeric contract"): energy cannot
    /// exceed 900 kcal per 100 g (pure fat, 9 kcal/g — olive oil is 884); a
    /// gram nutrient cannot exceed the 100 g food mass itself; mineral caps
    /// sit above the densest real food (salt carries 38,758 mg sodium,
    /// chalk 40,044 mg calcium, a KCl salt substitute ~52,400 mg potassium);
    /// vitamin caps sit above the richest foods (acerola 1,677 mg vitamin C,
    /// cod liver oil ~107,000 µg vitamin A, dried yeast ~3,100 µg folate).
    var presentValues: [(field: String, value: Double, range: ClosedRange<Double>)] {
        [
            ("energyKcal", energyKcal, 0...900),
            ("proteinG", proteinG, 0...100),
            ("carbohydrateG", carbohydrateG, 0...100),
            ("sugarG", sugarG, 0...100),
            ("fiberG", fiberG, 0...100),
            ("fatG", fatG, 0...100),
            ("saturatedFatG", saturatedFatG, 0...100),
            ("sodiumMg", sodiumMg, 0...40_000),
            ("potassiumMg", potassiumMg, 0...60_000),
            ("calciumMg", calciumMg, 0...40_000),
            ("ironMg", ironMg, 0...1_000),
            ("vitaminCMg", vitaminCMg, 0...2_000),
            ("vitaminARaeMcg", vitaminARaeMcg, 0...150_000),
            ("folateMcg", folateMcg, 0...5_000),
        ]
        .compactMap { field, value, range in value.map { (field, $0, range) } }
    }
}

public struct LearnCard: Codable, Sendable, Equatable {
    public struct Sections: Codable, Sendable, Equatable {
        public var whatItIs: CitedSection
        public var historyNote: CitedSection
        public var howToChoose: CitedSection
        public var storage: CitedSection
        public var useItUp: CitedSection
    }

    public var id: String
    public var displayName: String
    public var isCore: Bool
    public var category: String
    public var sections: Sections
    public var substitutions: [Substitution]?
    public var nutritionPer100g: NutritionPer100g?
    public var sources: [String: SourceRecord]
}

public extension LearnCard {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, isCore, category, sections
        case substitutions, nutritionPer100g, sources
    }

    /// Custom decoding so source records are keyed by id: the dictionary key
    /// IS the record's id, and any `id` field inside a record is ignored in
    /// favor of the key. Prevents id/key drift by construction.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        isCore = try c.decode(Bool.self, forKey: .isCore)
        category = try c.decode(String.self, forKey: .category)
        sections = try c.decode(Sections.self, forKey: .sections)
        substitutions = try c.decodeIfPresent([Substitution].self, forKey: .substitutions)
        nutritionPer100g = try c.decodeIfPresent(NutritionPer100g.self, forKey: .nutritionPer100g)
        let keyed = try c.decode([String: SourceBody].self, forKey: .sources)
        sources = Dictionary(
            keyed.map { key, body in
                (
                    key,
                    SourceRecord(
                        id: key, title: body.title, publisher: body.publisher,
                        url: body.url, retrieved: body.retrieved,
                        licence: body.licence, notes: body.notes
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

public extension LearnCard {
    /// Decodes and validates a learn-card file; refuses cards whose numbers
    /// have no resolvable source (`MissingSourceError`) rather than serving them.
    static func parse(from data: Data) throws -> LearnCard {
        let envelope = try DataEnvelope<LearnCard>.decode(data, expectingKind: "learn-card")
        return try validated(envelope.data)
    }

    static func validated(_ card: LearnCard) throws -> LearnCard {
        func resolve(_ section: CitedSection, _ name: String) throws {
            for citation in section.citations
            where card.sources[citation] == nil {
                throw MissingSourceError(
                    subject: "\(card.id).\(name)",
                    reason: "citation \(citation) not in sources"
                )
            }
        }
        try resolve(card.sections.whatItIs, "whatItIs")
        try resolve(card.sections.historyNote, "historyNote")
        try resolve(card.sections.howToChoose, "howToChoose")
        try resolve(card.sections.storage, "storage")
        try resolve(card.sections.useItUp, "useItUp")

        guard !card.sections.historyNote.citations.isEmpty else {
            throw MissingSourceError(
                subject: "\(card.id).historyNote",
                reason: "history note needs at least one citation"
            )
        }
        guard let safety = card.sections.storage.foodSafetyRef, !safety.path.isEmpty else {
            throw MissingSourceError(
                subject: "\(card.id).storage",
                reason: "storage must reference the food-safety rulebook"
            )
        }
        if let nutrition = card.nutritionPer100g {
            guard nutrition.fdcId > 0 else {
                throw MissingSourceError(
                    subject: "\(card.id).nutritionPer100g",
                    reason: "fdcId must be a positive row id"
                )
            }
            guard card.sources[nutrition.sourceId] != nil else {
                throw MissingSourceError(
                    subject: "\(card.id).nutritionPer100g",
                    reason: "nutrition sourceId '\(nutrition.sourceId)' not in sources"
                )
            }
            guard nutrition.nutrients.energyKcal != nil else {
                throw MissingSourceError(
                    subject: "\(card.id).nutritionPer100g",
                    reason: "energyKcal missing from the cited FDC row"
                )
            }
            // Impossible numbers refuse to load — never a silent 0 or nil.
            for (field, value, range) in nutrition.nutrients.presentValues
            where !(value.isFinite && range.contains(value)) {
                throw InvalidNumericError(
                    subject: "\(card.id).nutritionPer100g.nutrients",
                    field: field,
                    value: "\(value)",
                    reason: "outside the plausible per-100 g range "
                        + "\(range.lowerBound)...\(range.upperBound)"
                )
            }
        }
        return card
    }
}

/// The learn-cards index file's payload (data/kitchen-knowledge/learn-cards/index.json).
public struct LearnCardIndexEntry: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var displayName: String
    public var isCore: Bool
    public var category: String
    public var frequencyInBundledRecipes: Int?
    public var fdcId: Int?
}

public struct LearnCardCoverage: Codable, Sendable, Equatable {
    public var coreIngredients: Int?
    public var bundledDistinctIngredients: Int?
    public var cardsWritten: Int?
    public var missingNutrition: [String]?
    public var note: String?
}

public struct LearnCardIndexPayload: Codable, Sendable, Equatable {
    public var cards: [LearnCardIndexEntry]
    public var coverage: LearnCardCoverage?
}
