import Foundation
import MassConversionKit

// Source-bound checks over the pinned FNDDS conversion table:
//
//   1. Food-group-held-out recovery (leave-one-category-out): conversion
//      entries are grouped by WWEIA food category and one ENTIRE category
//      is withheld per arm, so no other record for the same food can stay
//      in the lookup while its sibling is queried (a per-entry offset
//      split would leave same-food records in training). Each withheld
//      entry is recovered with convert(food:unit:magnitude:) against the
//      reduced table. Reports per-category arms (sorted by category name)
//      plus an aggregate across arms, keeping the relErr / evidence /
//      unknown accounting and a worst-offenders list. This scores the
//      matcher's generalization with within-food leakage removed, not
//      entries' agreement with themselves.
//   2. 100-meal conversion-path plumbing check: 100 deterministic meals of
//      three ingredients each from the FNDDS food census. Queries are
//      token prefixes of the source description, so they always overlap
//      it — this exercises the end-to-end conversion path (unit choice,
//      lookup, evidence levels). It is NOT a name-resolution measure and
//      NOT a cooking-yield study; cooking-yield sensitivity is derived
//      source-bound by the Python driver (yield_sensitivity reports).
//
// Prints one JSON object to stdout; the Python driver captures it and
// writes the committed reports. Unknown conversions are never fabricated
// into a number, so every recovered figure comes from matched evidence.

/// One per-category arm of the leave-one-category-out protocol.
struct CategoryArm: Codable {
  let category: String
  let n: Int
  let matched: Int
  let unknown: Int
  let exact: Int
  let partial: Int
  let medianRelErrPct: Double
  let meanRelErrPct: Double
  let within25Pct: Int
  let within50Pct: Int
}

/// Aggregate accounting across all per-category arms.
struct AggregateResult: Codable {
  let n: Int
  let matched: Int
  let unknown: Int
  let exact: Int
  let partial: Int
  let medianRelErrPct: Double
  let meanRelErrPct: Double
  let within25Pct: Int
  let within50Pct: Int
  let worst: [Worst]
  struct Worst: Codable {
    let food: String
    let unit: String
    let actualGrams: Double
    let matchedGrams: Double
    let relErrPct: Double
    let withheldCategory: String
  }
}

struct HeldoutResult: Codable {
  let protocolName: String
  let categoryCount: Int
  let arms: [CategoryArm]
  let aggregate: AggregateResult

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case categoryCount, arms, aggregate
  }
}

struct MealsResult: Codable {
  let label: String
  let nMeals: Int
  let nIngredients: Int
  let convertedIngredients: Int
  let exactIngredients: Int
  let partialIngredients: Int
  let unknownIngredients: Int
  let ingredientYieldPct: Double
  let fullyConvertedMeals: Int
  let mealYieldPct: Double
}

struct Output: Codable {
  let heldout: HeldoutResult
  let meals: MealsResult
}

let table = try MassConversionTable.bundled

// 1. Food-group-held-out recovery: leave-one-WWEIA-category-out.
var entriesByCategory: [String: [MassConversionEntry]] = [:]
for portion in table.portions {
  entriesByCategory[portion.category ?? "", default: []].append(portion)
}
let categoryNames = entriesByCategory.keys.sorted()

func median(_ values: [Double]) -> Double {
  let s = values.sorted()
  guard !s.isEmpty else { return 0 }
  let mid = s.count / 2
  return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
}

var arms: [CategoryArm] = []
var pooledRelErrs: [Double] = []
var pooledExact = 0
var pooledPartial = 0
var pooledUnknown = 0
var worst: [AggregateResult.Worst] = []

for category in categoryNames {
  let withheld = entriesByCategory[category]!
  let reduced = MassConversionTable(
    source: table.source,
    portions: table.portions.filter { ($0.category ?? "") != category }
  )
  var relErrs: [Double] = []
  var exact = 0
  var partial = 0
  var unknown = 0

  for entry in withheld {
    if let conversion = reduced.convert(
      food: entry.food, unit: entry.unit, magnitude: entry.magnitude)
    {
      let relErr = abs(conversion.grams - entry.grams) / entry.grams * 100
      relErrs.append(relErr)
      pooledRelErrs.append(relErr)
      if conversion.evidence == .exact {
        exact += 1
        pooledExact += 1
      } else {
        partial += 1
        pooledPartial += 1
      }
      if conversion.fdcId != entry.fdcId {
        worst.append(
          AggregateResult.Worst(
            food: entry.food, unit: entry.unit.rawValue,
            actualGrams: entry.grams, matchedGrams: conversion.grams,
            relErrPct: relErr, withheldCategory: category))
      }
    } else {
      unknown += 1
      pooledUnknown += 1
    }
  }

  arms.append(
    CategoryArm(
      category: category,
      n: withheld.count,
      matched: relErrs.count,
      unknown: unknown,
      exact: exact,
      partial: partial,
      medianRelErrPct: relErrs.isEmpty ? 0 : median(relErrs),
      meanRelErrPct: relErrs.isEmpty
        ? 0 : relErrs.reduce(0, +) / Double(relErrs.count),
      within25Pct: relErrs.filter { $0 <= 25 }.count,
      within50Pct: relErrs.filter { $0 <= 50 }.count
    ))
}

worst.sort { $0.relErrPct > $1.relErrPct }

let heldoutResult = HeldoutResult(
  protocolName:
    "leave-one-WWEIA-category-out: the entire category is withheld per arm",
  categoryCount: categoryNames.count,
  arms: arms,
  aggregate: AggregateResult(
    n: pooledRelErrs.count + pooledUnknown,
    matched: pooledRelErrs.count,
    unknown: pooledUnknown,
    exact: pooledExact,
    partial: pooledPartial,
    medianRelErrPct: pooledRelErrs.isEmpty ? 0 : median(pooledRelErrs),
    meanRelErrPct: pooledRelErrs.isEmpty
      ? 0 : pooledRelErrs.reduce(0, +) / Double(pooledRelErrs.count),
    within25Pct: pooledRelErrs.filter { $0 <= 25 }.count,
    within50Pct: pooledRelErrs.filter { $0 <= 50 }.count,
    worst: Array(worst.prefix(5))
  )
)

// 2. 100-meal conversion-path plumbing check (not a yield study).
let unitPreference = [
  "cup", "tbsp", "piece", "slice", "oz", "egg", "tsp", "medium", "large",
  "small", "floz", "stick", "pat", "clove", "ear", "can", "package",
  "envelope", "strip", "regular", "quart", "pint", "gallon", "liter", "lb",
]
var foodsToUnits: [String: [HouseholdUnit]] = [:]
for portion in table.portions {
  foodsToUnits[portion.food, default: []].append(portion.unit)
}
let distinctFoods = foodsToUnits.keys.sorted()
let nMeals = 100
let perMeal = 3

var ingredients = 0
var convertedIngredients = 0
var exactIngredients = 0
var partialIngredients = 0
var unknownIngredients = 0
var fullyConvertedMeals = 0

for meal in 0..<nMeals {
  var convertedInMeal = 0
  for j in 0..<perMeal {
    let food = distinctFoods[(meal * perMeal + j) % distinctFoods.count]
    ingredients += 1
    let units = foodsToUnits[food]!
    let chosen = unitPreference.lazy.compactMap { name in
      units.first { $0.rawValue == name }
    }.first
    guard let unit = chosen else {
      unknownIngredients += 1
      continue
    }
    // Realistic intake-style query: the leading words of the description
    // (up to 3). Note: a prefix query always overlaps its own description,
    // so this measures end-to-end path coverage, not name-resolution
    // difficulty and not cooking yield — the held-out arms above cover
    // resolution error, and the driver derives yield sensitivity from
    // source-bound raw/cooked pairs.
    let words =
      food
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .prefix(3)
    let query = words.joined(separator: " ")
    if let conversion = table.convert(food: query, unit: unit, magnitude: 1) {
      convertedIngredients += 1
      convertedInMeal += 1
      if conversion.evidence == .exact { exactIngredients += 1 } else {
        partialIngredients += 1
      }
    } else {
      unknownIngredients += 1
    }
  }
  if convertedInMeal == perMeal { fullyConvertedMeals += 1 }
}

let mealsResult = MealsResult(
  label:
    "conversion-path plumbing check: prefix queries always overlap their "
    + "source description — not a name-resolution measure, not a yield study",
  nMeals: nMeals,
  nIngredients: ingredients,
  convertedIngredients: convertedIngredients,
  exactIngredients: exactIngredients,
  partialIngredients: partialIngredients,
  unknownIngredients: unknownIngredients,
  ingredientYieldPct: Double(convertedIngredients) / Double(ingredients) * 100,
  fullyConvertedMeals: fullyConvertedMeals,
  mealYieldPct: Double(fullyConvertedMeals) / Double(nMeals) * 100
)

let output = Output(heldout: heldoutResult, meals: mealsResult)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let data = try encoder.encode(output)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
