import Foundation

// MARK: - Quantity evidence
// SPEC 3.5 / engineering plan Goal 4: ingredient lines carry quantity evidence —
// weighed, source grams, a household measure with conversion evidence, or unknown.
// Unknown is a first-class value: it means no evidence exists, and no number may be
// invented downstream (never a default 50 g).

/// A mass in grams. Zero is allowed (a pinch scaled to zero servings); negative
/// and non-finite values are rejected at construction.
public struct GramMass: Hashable, Sendable {
    public let grams: Double

    public init(grams: Double) throws {
        guard grams.isFinite else {
            throw FLDomainError.validation(target: "GramMass.grams", reason: "must be finite (got \(grams))")
        }
        guard grams >= 0 else {
            throw FLDomainError.validation(target: "GramMass.grams", reason: "must be non-negative (got \(grams))")
        }
        self.grams = grams
    }
}

extension GramMass: Codable {
    private enum CodingKeys: String, CodingKey { case grams }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(grams: try container.decode(Double.self, forKey: .grams))
    }
}

/// A household measure ("1 cup", "2 large eggs") plus the evidence that converts
/// it to grams. The conversion source is required: a number without provenance
/// is not evidence.
public struct HouseholdMeasure: Hashable, Sendable {
    /// Count of `unit`. Finite, non-negative.
    public let amount: Double
    /// Household unit name, e.g. "cup", "tbsp", "large egg". Never empty.
    public let unit: String
    /// Grams for one `unit`. Finite, strictly positive: a zero conversion factor
    /// would silently turn any amount into nothing.
    public let gramsPerUnit: Double
    /// Where the conversion comes from, e.g. "USDA FNDDS: 1 cup whole milk = 244 g".
    /// Never empty.
    public let conversionSource: String

    public init(amount: Double, unit: String, gramsPerUnit: Double, conversionSource: String) throws {
        guard amount.isFinite, amount >= 0 else {
            throw FLDomainError.validation(target: "HouseholdMeasure.amount", reason: "must be finite and non-negative (got \(amount))")
        }
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUnit.isEmpty else {
            throw FLDomainError.validation(target: "HouseholdMeasure.unit", reason: "must not be empty")
        }
        guard gramsPerUnit.isFinite, gramsPerUnit > 0 else {
            throw FLDomainError.validation(target: "HouseholdMeasure.gramsPerUnit", reason: "must be finite and > 0 (got \(gramsPerUnit))")
        }
        let trimmedSource = conversionSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            throw FLDomainError.validation(target: "HouseholdMeasure.conversionSource", reason: "must not be empty")
        }
        self.amount = amount
        self.unit = trimmedUnit
        self.gramsPerUnit = gramsPerUnit
        self.conversionSource = trimmedSource
    }

    /// The total mass this measure converts to, with the same evidence rules.
    public var totalGrams: GramMass {
        get throws {
            try GramMass(grams: amount * gramsPerUnit)
        }
    }
}

extension HouseholdMeasure: Codable {
    private enum CodingKeys: String, CodingKey {
        case amount, unit, gramsPerUnit, conversionSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            amount: try container.decode(Double.self, forKey: .amount),
            unit: try container.decode(String.self, forKey: .unit),
            gramsPerUnit: try container.decode(Double.self, forKey: .gramsPerUnit),
            conversionSource: try container.decode(String.self, forKey: .conversionSource)
        )
    }
}

/// How much of one ingredient line the recipe asks for, and what justifies the
/// number. `unknown` is first-class: it never becomes a number by default, and
/// it blocks complete feasibility and complete nutrition claims.
public enum QuantityEvidence: Hashable, Sendable {
    /// Weighed on a scale.
    case weighedGrams(GramMass)
    /// The source text itself states grams.
    case sourceGrams(GramMass)
    /// A household measure with conversion evidence.
    case householdMeasure(HouseholdMeasure)
    /// No evidence exists. Stays unknown until real evidence arrives.
    case unknown
}

public extension QuantityEvidence {
    /// The mass in grams when the evidence carries one, otherwise `nil`.
    /// Unknown and household measures without a resolvable total return `nil` —
    /// callers must not substitute a number.
    var gramsIfKnown: GramMass? {
        switch self {
        case let .weighedGrams(mass): return mass
        case let .sourceGrams(mass): return mass
        case let .householdMeasure(measure): return try? measure.totalGrams
        case .unknown: return nil
        }
    }

    /// True only when the evidence is `.unknown`. Recognition confidence is not
    /// quantity confidence (SPEC 3.2): a confident detection of an unknown
    /// amount is still unknown.
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

extension QuantityEvidence: Codable {
    private enum CodingKeys: String, CodingKey { case kind, grams, measure }

    private enum Kind: String, Codable, Sendable {
        case weighedGrams, sourceGrams, householdMeasure, unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .weighedGrams:
            self = .weighedGrams(try container.decode(GramMass.self, forKey: .grams))
        case .sourceGrams:
            self = .sourceGrams(try container.decode(GramMass.self, forKey: .grams))
        case .householdMeasure:
            self = .householdMeasure(try container.decode(HouseholdMeasure.self, forKey: .measure))
        case .unknown:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .weighedGrams(mass):
            try container.encode(Kind.weighedGrams, forKey: .kind)
            try container.encode(mass, forKey: .grams)
        case let .sourceGrams(mass):
            try container.encode(Kind.sourceGrams, forKey: .kind)
            try container.encode(mass, forKey: .grams)
        case let .householdMeasure(measure):
            try container.encode(Kind.householdMeasure, forKey: .kind)
            try container.encode(measure, forKey: .measure)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}
