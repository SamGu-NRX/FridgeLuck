import Foundation
import MassConversionKit

// Source-bound checks over the pinned FNDDS conversion table:
//
//   1. Held-out recovery: withhold every 10th entry (sorted by
//      fdcId, unit, magnitude — deterministic), match its own food + unit
//      against the remaining table, and measure how well the matcher
//      recovers the withheld grams. This scores the matcher's
//      generalization, not entries' agreement with themselves.
//   2. 100-meal conversion yield: build 100 deterministic meals of three
//      ingredients each from the FNDDS food census and measure the fraction
//      of ingredients that convert with evidence (exact or partial) rather
//      than falling to unknown.
//
// Prints one JSON object to stdout; the Python driver captures it and writes
// the committed reports. Unknown conversions are never fabricated into a
// number, so yield is a coverage metric.

struct HeldoutResult: Codable {
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
  }
}

struct MealsResult: Codable {
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

// 1. Held-out recovery.
let sorted = table.portions.sorted { a, b in
  if a.fdcId != b.fdcId { return a.fdcId < b.fdcId }
  if a.unit.rawValue != b.unit.rawValue {
    return a.unit.rawValue < b.unit.rawValue
  }
  return a.magnitude < b.magnitude
}
let heldout = sorted.enumerated().filter { $0.offset % 10 == 0 }

var relErrs: [Double] = []
var exact = 0
var partial = 0
var unknown = 0
var worst: [HeldoutResult.Worst] = []

for (offset, entry) in heldout {
  _ = offset
  let reduced = MassConversionTable(
    source: table.source,
    portions: table.portions.filter { $0 != entry }
  )
  if let conversion = reduced.convert(
    food: entry.food, unit: entry.unit, magnitude: entry.magnitude)
  {
    relErrs.append(abs(conversion.grams - entry.grams) / entry.grams * 100)
    if conversion.evidence == .exact { exact += 1 } else { partial += 1 }
    if conversion.fdcId != entry.fdcId {
      worst.append(
        HeldoutResult.Worst(
          food: entry.food, unit: entry.unit.rawValue,
          actualGrams: entry.grams, matchedGrams: conversion.grams,
          relErrPct: relErrs.last!))
    }
  } else {
    unknown += 1
  }
}

func median(_ values: [Double]) -> Double {
  let s = values.sorted()
  guard !s.isEmpty else { return 0 }
  let mid = s.count / 2
  return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
}

worst.sort { $0.relErrPct > $1.relErrPct }

let heldoutResult = HeldoutResult(
  n: heldout.count,
  matched: relErrs.count,
  unknown: unknown,
  exact: exact,
  partial: partial,
  medianRelErrPct: relErrs.isEmpty ? 0 : median(relErrs),
  meanRelErrPct: relErrs.isEmpty
    ? 0 : relErrs.reduce(0, +) / Double(relErrs.count),
  within25Pct: relErrs.filter { $0 <= 25 }.count,
  within50Pct: relErrs.filter { $0 <= 50 }.count,
  worst: Array(worst.prefix(5))
)

// 2. 100-meal conversion yield.
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
    // difficulty — the held-out arm above covers resolution error.
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
