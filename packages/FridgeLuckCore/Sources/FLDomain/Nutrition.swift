import Foundation

// MARK: - Nutrition with explicit coverage
// SPEC 3.2/3.5 + engineering plan Goal 4: nutrients come from known per-100 g
// values and quantity evidence. Sodium is stored in GRAMS here; milligrams
// appear only at the display boundary. Unknown mass or nutrients stay unknown;
// partial nutrition reports which lines are missing.

/// The core nutrient lines the app reasons about. Every value is optional: an
/// absent line is an honest gap, never a zero.
public struct NutritionValues: Hashable, Sendable {
    public let caloriesKcal: Double?
    public let proteinGrams: Double?
    public let carbohydrateGrams: Double?
    public let fatGrams: Double?
    public let saturatedFatGrams: Double?
    public let fiberGrams: Double?
    public let sugarGrams: Double?
    /// Sodium in grams. Convert to milligrams only at the display boundary
    /// (grams × 1000).
    public let sodiumGrams: Double?

    public static let lineNames: [String] = [
        "caloriesKcal", "proteinGrams", "carbohydrateGrams", "fatGrams",
        "saturatedFatGrams", "fiberGrams", "sugarGrams", "sodiumGrams",
    ]

    public init(
        caloriesKcal: Double? = nil,
        proteinGrams: Double? = nil,
        carbohydrateGrams: Double? = nil,
        fatGrams: Double? = nil,
        saturatedFatGrams: Double? = nil,
        fiberGrams: Double? = nil,
        sugarGrams: Double? = nil,
        sodiumGrams: Double? = nil
    ) throws {
        func validated(_ value: Double?, _ name: String) throws -> Double? {
            if let value {
                guard value.isFinite, value >= 0 else {
                    throw FLDomainError.validation(target: "NutritionValues.\(name)", reason: "must be finite and non-negative (got \(value))")
                }
            }
            return value
        }
        self.caloriesKcal = try validated(caloriesKcal, "caloriesKcal")
        self.proteinGrams = try validated(proteinGrams, "proteinGrams")
        self.carbohydrateGrams = try validated(carbohydrateGrams, "carbohydrateGrams")
        self.fatGrams = try validated(fatGrams, "fatGrams")
        self.saturatedFatGrams = try validated(saturatedFatGrams, "saturatedFatGrams")
        self.fiberGrams = try validated(fiberGrams, "fiberGrams")
        self.sugarGrams = try validated(sugarGrams, "sugarGrams")
        self.sodiumGrams = try validated(sodiumGrams, "sodiumGrams")
    }

    /// The value of a line by its canonical name, or `nil`.
    public func value(forLine line: String) -> Double? {
        switch line {
        case "caloriesKcal": return caloriesKcal
        case "proteinGrams": return proteinGrams
        case "carbohydrateGrams": return carbohydrateGrams
        case "fatGrams": return fatGrams
        case "saturatedFatGrams": return saturatedFatGrams
        case "fiberGrams": return fiberGrams
        case "sugarGrams": return sugarGrams
        case "sodiumGrams": return sodiumGrams
        default: return nil
        }
    }

    /// True when every core line has a value.
    public var isComplete: Bool {
        Self.lineNames.allSatisfy { value(forLine: $0) != nil }
    }

    /// The names of lines that are absent.
    public var missingLines: [String] {
        Self.lineNames.filter { value(forLine: $0) == nil }
    }

    /// True when at least one line has a value.
    public var hasAnyLine: Bool {
        Self.lineNames.contains { value(forLine: $0) != nil }
    }
}

extension NutritionValues: Codable {
    private enum CodingKeys: String, CodingKey {
        case caloriesKcal, proteinGrams, carbohydrateGrams, fatGrams
        case saturatedFatGrams, fiberGrams, sugarGrams, sodiumGrams
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            caloriesKcal: try container.decodeIfPresent(Double.self, forKey: .caloriesKcal),
            proteinGrams: try container.decodeIfPresent(Double.self, forKey: .proteinGrams),
            carbohydrateGrams: try container.decodeIfPresent(Double.self, forKey: .carbohydrateGrams),
            fatGrams: try container.decodeIfPresent(Double.self, forKey: .fatGrams),
            saturatedFatGrams: try container.decodeIfPresent(Double.self, forKey: .saturatedFatGrams),
            fiberGrams: try container.decodeIfPresent(Double.self, forKey: .fiberGrams),
            sugarGrams: try container.decodeIfPresent(Double.self, forKey: .sugarGrams),
            sodiumGrams: try container.decodeIfPresent(Double.self, forKey: .sodiumGrams)
        )
    }
}

/// Explicit nutrition coverage (SPEC: complete / partial with the missing lines
/// / unknown). Coverage must be coherent with the values: a report never claims
/// complete when lines are absent, and never claims unknown when a line exists.
public enum NutritionCoverage: Hashable, Sendable {
    /// Every core line has a value.
    case complete
    /// Some lines are missing; the missing line names travel with the report.
    case partial(missingLines: [String])
    /// Nothing is known. No number may be presented.
    case unknown
}

extension NutritionCoverage: Codable {
    private enum CodingKeys: String, CodingKey { case kind, missingLines }

    private enum Kind: String, Codable, Sendable { case complete, partial, unknown }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .complete:
            self = .complete
        case .partial:
            self = .partial(missingLines: try container.decode([String].self, forKey: .missingLines))
        case .unknown:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .complete:
            try container.encode(Kind.complete, forKey: .kind)
        case let .partial(missingLines):
            try container.encode(Kind.partial, forKey: .kind)
            try container.encode(missingLines, forKey: .missingLines)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}

/// Nutrition values plus their explicit coverage, validated for coherence.
public struct NutritionReport: Hashable, Sendable {
    public let values: NutritionValues
    public let coverage: NutritionCoverage

    public init(values: NutritionValues, coverage: NutritionCoverage) throws {
        switch coverage {
        case .complete:
            guard values.isComplete else {
                throw FLDomainError.validation(
                    target: "NutritionReport.coverage",
                    reason: "coverage claims complete but lines are missing: \(values.missingLines)"
                )
            }
        case let .partial(missingLines):
            guard !missingLines.isEmpty else {
                throw FLDomainError.validation(
                    target: "NutritionReport.coverage",
                    reason: "partial coverage must name the missing lines"
                )
            }
            for line in missingLines where values.value(forLine: line) != nil {
                throw FLDomainError.validation(
                    target: "NutritionReport.coverage",
                    reason: "line \(line) is listed as missing but has a value"
                )
            }
            guard values.hasAnyLine else {
                throw FLDomainError.validation(
                    target: "NutritionReport.coverage",
                    reason: "partial coverage requires at least one known line; all-unknown is .unknown"
                )
            }
        case .unknown:
            guard !values.hasAnyLine else {
                throw FLDomainError.validation(
                    target: "NutritionReport.coverage",
                    reason: "coverage claims unknown but some lines have values: \(values.missingLines)"
                )
            }
        }
        self.values = values
        self.coverage = coverage
    }
}

extension NutritionReport: Codable {
    private enum CodingKeys: String, CodingKey { case values, coverage }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            values: try container.decode(NutritionValues.self, forKey: .values),
            coverage: try container.decode(NutritionCoverage.self, forKey: .coverage)
        )
    }
}
