import Foundation

import EstimatorReplay

/// Reads a source-bound example set (JSON) and replays the production
/// InventoryIntakeService gram estimator on every example.
///
/// Usage: estimator-eval <examples.json> [output.json]
///
/// Example schema (written by scripts/data/evaluate_mass_estimates.py):
///   {"examples": [{
///        "fdcId": 2705385, "food": "Milk, whole", "portion": "1 cup",
///        "unit": "cup", "usdaGrams": 244.0 }]}
///
/// Arms replayed (the estimator itself is never modified):
///   nameArm          estimateGrams(forName:) on the FNDDS description
///   unitArm          estimateGrams(for:) with the canonical unit word
///   unitPrefixedArm  estimateGrams(for:) with "1 <unit>"
///
/// Output: {"results": [...], "source": {...}} printed to stdout or written
/// to the optional output path.

struct Example: Decodable {
  let fdcId: Int
  let food: String
  let portion: String
  let unit: String
  let usdaGrams: Double
}

struct ExampleFile: Decodable {
  let examples: [Example]
}

struct Result: Encodable {
  let fdcId: Int
  let food: String
  let portion: String
  let unit: String
  let usdaGrams: Double
  let nameArmGrams: Double
  let unitArmGrams: Double
  let unitPrefixedArmGrams: Double
}

struct Output: Encodable {
  let results: [Result]
}

guard CommandLine.arguments.count >= 2 else {
  FileHandle.standardError.write("usage: estimator-eval <examples.json>\n".data(using: .utf8)!)
  exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: inputURL)
let exampleFile = try JSONDecoder().decode(ExampleFile.self, from: data)

var results: [Result] = []
for example in exampleFile.examples {
  let nameGrams = EstimatorReplay.estimatedGrams(forName: example.food)
  let unitGrams = EstimatorReplay.estimatedGrams(
    for: ReplayIngredient(typicalUnit: example.unit))
  let prefixedGrams = EstimatorReplay.estimatedGrams(
    for: ReplayIngredient(typicalUnit: "1 \(example.unit)"))
  results.append(
    Result(
      fdcId: example.fdcId,
      food: example.food,
      portion: example.portion,
      unit: example.unit,
      usdaGrams: example.usdaGrams,
      nameArmGrams: nameGrams,
      unitArmGrams: unitGrams,
      unitPrefixedArmGrams: prefixedGrams))
}

let output = Output(results: results)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let encoded = try encoder.encode(output)

if CommandLine.arguments.count >= 3 {
  try encoded.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
} else {
  FileHandle.standardOutput.write(encoded)
}
