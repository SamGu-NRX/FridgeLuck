import Foundation

/// Why the portion field can't produce values yet, in the order the sheet needs them.
///
/// Each case carries a specific, VoiceOver-readable message: "invalid input" alone doesn't tell
/// someone whether to fix a typo or start over. Empty input is an invitation, not a failure.
public enum IngredientFactsInputError: Equatable, Error, Sendable {
  /// The field is blank. Nothing has been asked yet.
  case empty
  /// The text isn't a number at all ("abc", "1..2").
  case notANumber
  /// The text parses but isn't a finite number ("nan", "inf", "1e309").
  case notFinite
  /// The weight isn't greater than zero (0, -5).
  case notPositive
  /// The weight is finite but so large that scaled values overflow ("1e308").
  case unsupportedMagnitude
  /// The stored nutrition itself can't be scaled (a non-finite stored value).
  case unsupportedReference

  public var errorMessage: String {
    switch self {
    case .empty:
      return "Enter a weight in grams to see the values for that portion."
    case .notANumber:
      return "Enter a number of grams, like 150 or 62.5."
    case .notFinite:
      return "Enter a finite weight in grams."
    case .notPositive:
      return "Portion weight must be greater than 0 grams."
    case .unsupportedMagnitude:
      return "That weight is too large to calculate values for."
    case .unsupportedReference:
      return "Stored nutrition for this ingredient can't be scaled. Showing the reference instead."
    }
  }
}

/// What the portion field currently resolves to. Equatable so the offline check package can pin it.
public enum IngredientFactsPortionOutcome: Equatable, Sendable {
  case empty
  case valid(IngredientFactsPortion)
  case failed(IngredientFactsInputError)
}

/// The stored nutrition values of one ingredient record, as entered.
///
/// `suppliedDescription` is carried verbatim and displayed verbatim. It is supplied text, never
/// verified provenance: the sheet must not label a description-free record as USDA or measured data.
public struct IngredientFactsRecord: Equatable, Sendable {
  public let energyKilocalories: Double
  public let proteinGrams: Double
  public let carbohydrateGrams: Double
  public let fatGrams: Double
  public let fiberGrams: Double
  public let sugarGrams: Double
  public let sodiumGrams: Double
  public let suppliedDescription: String?

  public init(
    energyKilocalories: Double,
    proteinGrams: Double,
    carbohydrateGrams: Double,
    fatGrams: Double,
    fiberGrams: Double,
    sugarGrams: Double,
    sodiumGrams: Double,
    suppliedDescription: String? = nil
  ) {
    self.energyKilocalories = energyKilocalories
    self.proteinGrams = proteinGrams
    self.carbohydrateGrams = carbohydrateGrams
    self.fatGrams = fatGrams
    self.fiberGrams = fiberGrams
    self.sugarGrams = sugarGrams
    self.sodiumGrams = sodiumGrams
    self.suppliedDescription = suppliedDescription
  }
}

/// The immutable per-100 g reference: stored energy stays authoritative, sodium converts
/// from stored grams to milligrams exactly once, here.
public struct IngredientFactsReference: Equatable, Sendable {
  public let energyKilocalories: Double
  public let proteinGrams: Double
  public let carbohydrateGrams: Double
  public let fatGrams: Double
  public let fiberGrams: Double
  public let sugarGrams: Double
  public let sodiumMilligrams: Double

  public init(record: IngredientFactsRecord) {
    self.energyKilocalories = record.energyKilocalories
    self.proteinGrams = record.proteinGrams
    self.carbohydrateGrams = record.carbohydrateGrams
    self.fatGrams = record.fatGrams
    self.fiberGrams = record.fiberGrams
    self.sugarGrams = record.sugarGrams
    // Single conversion point: stored grams per 100 g -> displayed milligrams per 100 g.
    self.sodiumMilligrams = (record.sodiumGrams * 1000).rounded()
  }

  /// True when every value can be scaled without producing non-finite output.
  public var isScalable: Bool {
    [
      energyKilocalories, proteinGrams, carbohydrateGrams, fatGrams, fiberGrams, sugarGrams,
      sodiumMilligrams,
    ]
    .allSatisfy { $0.isFinite }
  }
}

/// The values for one entered weight. Built only by `IngredientFactsModel` from the reference.
public struct IngredientFactsPortion: Equatable, Sendable {
  public let grams: Double
  public let energyKilocalories: Double
  public let proteinGrams: Double
  public let carbohydrateGrams: Double
  public let fatGrams: Double
  public let fiberGrams: Double
  public let sugarGrams: Double
  public let sodiumMilligrams: Double
}

/// Immutable presentation model for the ingredient detail sheet.
///
/// The reference is fixed at construction; portions are derived per lookup and never mutate
/// anything. Energy is the stored value scaled — it is never re-derived from macro factors.
/// There is no serving denominator, density, cup, piece or intake estimate anywhere in here.
public struct IngredientFactsModel: Equatable, Sendable {
  public let record: IngredientFactsRecord
  public let reference: IngredientFactsReference

  public init(record: IngredientFactsRecord) {
    self.record = record
    self.reference = IngredientFactsReference(record: record)
  }

  /// Parses entered portion text (grams, decimal point or comma) into an outcome.
  /// Invalid text leaves the reference untouched — it is only ever read.
  public func portionOutcome(forText text: String) -> IngredientFactsPortionOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .empty }
    guard reference.isScalable else { return .failed(.unsupportedReference) }

    let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
    guard let grams = Double(normalized) else { return .failed(.notANumber) }
    guard grams.isFinite else { return .failed(.notFinite) }
    guard grams > 0 else { return .failed(.notPositive) }
    return portionOutcome(forGrams: grams)
  }

  /// Scales the reference to a finite positive weight.
  public func portionOutcome(forGrams grams: Double) -> IngredientFactsPortionOutcome {
    guard reference.isScalable else { return .failed(.unsupportedReference) }
    guard grams.isFinite else { return .failed(.notFinite) }
    guard grams > 0 else { return .failed(.notPositive) }

    let factor = grams / 100
    let energy = reference.energyKilocalories * factor
    let protein = reference.proteinGrams * factor
    let carbohydrate = reference.carbohydrateGrams * factor
    let fat = reference.fatGrams * factor
    let fiber = reference.fiberGrams * factor
    let sugar = reference.sugarGrams * factor
    let sodium = reference.sodiumMilligrams * factor

    let scaled = [grams, energy, protein, carbohydrate, fat, fiber, sugar, sodium]
    guard scaled.allSatisfy({ $0.isFinite }) else { return .failed(.unsupportedMagnitude) }

    return .valid(
      IngredientFactsPortion(
        grams: grams,
        energyKilocalories: energy,
        proteinGrams: protein,
        carbohydrateGrams: carbohydrate,
        fatGrams: fat,
        fiberGrams: fiber,
        sugarGrams: sugar,
        sodiumMilligrams: sodium
      ))
  }
}

/// Display strings for fact values, shared by the reference and portion cards so both
/// render the same stored number the same way. Non-finite values render as an em dash
/// rather than "nan"/"inf".
public enum IngredientFactsQuantity {
  public static func grams(_ value: Double) -> String {
    value.isFinite ? String(format: "%.1fg", value) : "—"
  }

  public static func kilocalories(_ value: Double) -> String {
    value.isFinite ? "\(Int(value.rounded())) kcal" : "—"
  }

  public static func milligrams(_ value: Double) -> String {
    value.isFinite ? "\(Int(value.rounded()))mg" : "—"
  }
}
