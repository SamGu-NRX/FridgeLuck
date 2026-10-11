import Foundation
import WeeklyPlanCore

// MARK: - CLI
//
// Subcommands:
//   WeeklyPlanEval [--seed N] [--count N] [--output PATH] [--verify-report PATH]
//       Runs the seeded evaluation and prints/writes the JSON report.
//       `--verify-report` re-runs the eval and compares every deterministic
//       field (all counts, objective stats, corpus digest) against the stored
//       report; runtime and timestamp are ignored. Exit 0 on match.
//   BruteForceCheck
//       Runs the oracle-agreement sweep and infeasible controls with hard
//       assertions. Exit 0 only if every assertion holds.
//   help — this text.

func encodeJSON<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
  return try encoder.encode(value)
}

func decodeReport(_ data: Data) -> WeeklyPlanEvalReport? {
  try? JSONDecoder().decode(WeeklyPlanEvalReport.self, from: data)
}

func needText(_ recipe: WeeklyPlanRecipe) -> String {
  recipe.needs
    .map { "i=\($0.ingredientId) g=\($0.gramsPerServing) opt=\($0.isOptional) subs=\($0.substitutes)" }
    .joined(separator: ",")
}

func engineVerdictText(_ result: WeeklyPlanResult) -> String {
  if case .infeasible(let violations) = result.verdict {
    return violations.map(WeeklyPlanViolationText.describe).joined(separator: " | ")
  }
  return ""
}

func engineVerdictIDs(_ result: WeeklyPlanResult) -> String {
  result.assignments.map { "\($0.slotId)->\($0.recipeId)" }.joined(separator: ",")
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
  exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first else {
  print("usage: weekly-plan-check <WeeklyPlanEval|BruteForceCheck|help> [options]")
  exit(2)
}
arguments.removeFirst()

switch command {
case "help", "--help", "-h":
  print(
    """
    usage:
      WeeklyPlanEval [--seed N] [--count N] [--output PATH] [--verify-report PATH]
      BruteForceCheck

    WeeklyPlanEval runs the seeded synthetic-household evaluation and prints a
    JSON report (or writes it to --output). --verify-report re-runs the eval
    and checks every deterministic field against the stored report.
    """
  )
  exit(0)

case "BruteForceCheck":
  var generator = HouseholdGenerator(seed: 20261010)
  let states = generator.generate(count: 120)
  var checked = 0
  var disagreements = 0
  for input in states where input.recipes.count <= 6 && input.slots.count <= 3 {
    let engine = WeeklyPlanEngine.plan(input)
    let oracle = WeeklyPlanOracle.plan(input)
    checked += 1
    let engineFeasible = engine.verdict == WeeklyPlanVerdict.feasible
    let oracleFeasible = oracle.verdict == WeeklyPlanVerdict.feasible
    if engineFeasible != oracleFeasible {
      disagreements += 1
      if disagreements == 1 {
        print("FIRST DISAGREEMENT (feasibility):")
        print("  engine: \(engineFeasible ? "feasible" : "infeasible") \(engineVerdictText(engine))")
        print("  oracle: \(oracleFeasible ? "feasible" : "infeasible") \(engineVerdictText(oracle))")
        print("  recipes: \(input.recipes.map { "id=\($0.id) time=\($0.timeMinutes) diet=\($0.dietClass ?? "-") needs=\(needText($0))" }.joined(separator: "; "))")
        print("  slots: \(input.slots.map { "\($0.id)" }.joined(separator: ","))")
        print("  stock: \(input.stock.map { "id=\($0.ingredientId) g=\($0.availableGrams) known=\($0.quantityIsKnown)" }.joined(separator: "; "))")
        print("  constraints: excluded=\(input.constraints.excludedIngredientIds.sorted()) diet=\(input.constraints.requiredDietClass ?? "-") time=\(input.constraints.maxCookTimeMinutes.map(String.init) ?? "-") servings=\(input.constraints.servingsPerMeal) repeats=\(input.constraints.maxRepeatsPerRecipe)")
        print("  engineIDs=\(engineVerdictIDs(engine)) oracleIDs=\(engineVerdictIDs(oracle))")
      }
      continue
    }
    if engineFeasible && abs(engine.score - oracle.score) > 1e-9 {
      disagreements += 1
      if disagreements == 1 || engineVerdictIDs(engine) != engineVerdictIDs(oracle) {
        print("DISAGREEMENT (score):")
        print("  engineIDs=\(engineVerdictIDs(engine)) oracleIDs=\(engineVerdictIDs(oracle))")
        print("  engineScore=\(engine.score) oracleScore=\(oracle.score)")
        print("  recipes: \(input.recipes.map { "id=\($0.id) time=\($0.timeMinutes) needs=\(needText($0))" }.joined(separator: "; "))")
        print("  slots: \(input.slots.map { "\($0.id)" }.joined(separator: ","))")
        print("  stock: \(input.stock.map { "id=\($0.ingredientId) g=\($0.availableGrams) known=\($0.quantityIsKnown)" }.joined(separator: "; "))")
        print("  constraints: excluded=\(input.constraints.excludedIngredientIds.sorted()) diet=\(input.constraints.requiredDietClass ?? "-") time=\(input.constraints.maxCookTimeMinutes.map(String.init) ?? "-") servings=\(input.constraints.servingsPerMeal) repeats=\(input.constraints.maxRepeatsPerRecipe)")
        print("  objective: \(input.objective)")
      }
    }
  }
  let controls = [
    HouseholdGenerator.waiverTemptation(excluded: 7, sub: 8),
    HouseholdGenerator.waiverTemptation(excluded: 3, sub: 4),
    HouseholdGenerator.waiverTemptation(excluded: 39, sub: 40),
  ]
  let controlFailures = controls.filter { WeeklyPlanEngine.plan($0).verdict == WeeklyPlanVerdict.feasible }.count

  print("brute-force agreement pairs checked: \(checked)")
  print("disagreements: \(disagreements)")
  print("infeasible control failures: \(controlFailures)")
  exit(disagreements == 0 && controlFailures == 0 ? 0 : 1)

case "WeeklyPlanEval":
  var seed: UInt64 = 20261010
  var count = 1000
  var output: String? = nil
  var verifyPath: String? = nil

  var iterator = arguments.makeIterator()
  while let flag = iterator.next() {
    switch flag {
    case "--seed":
      guard let raw = iterator.next(), let value = UInt64(raw) else { fail("--seed needs an integer") }
      seed = value
    case "--count":
      guard let raw = iterator.next(), let value = Int(raw), value > 0 else { fail("--count needs a positive integer") }
      count = value
    case "--output":
      guard let path = iterator.next() else { fail("--output needs a path") }
      output = path
    case "--verify-report":
      guard let path = iterator.next() else { fail("--verify-report needs a path") }
      verifyPath = path
    default:
      fail("unknown flag \(flag)")
    }
  }

  let report = WeeklyPlanEvalReport.run(seed: seed, count: count)

  if let verifyPath {
    guard let stored = decodeReport(try Data(contentsOf: URL(fileURLWithPath: verifyPath))) else {
      fail("could not read or parse report at \(verifyPath)")
    }
    if stored.verifiedFields == report.verifiedFields {
      print("verify OK: deterministic report fields match \(verifyPath)")
      exit(0)
    } else {
      FileHandle.standardError.write("verify FAILED: deterministic report fields differ\n".data(using: .utf8)!)
      let storedJSON = try? String(data: encodeJSON(stored.verifiedFields), encoding: .utf8) ?? ""
      let freshJSON = try? String(data: encodeJSON(report.verifiedFields), encoding: .utf8) ?? ""
      FileHandle.standardError.write(("stored: " + (storedJSON ?? "") + "\n").data(using: .utf8)!)
      FileHandle.standardError.write(("fresh:  " + (freshJSON ?? "") + "\n").data(using: .utf8)!)
      exit(1)
    }
  }

  let data = try encodeJSON(report)
  if let output {
    try data.write(to: URL(fileURLWithPath: output))
    print("report written to \(output)")
  } else {
    print(String(data: data, encoding: .utf8) ?? "")
  }
  // The eval reports; it fails only on actual violations.
  exit(
    report.counts.hardExclusionViolations == 0
      && report.counts.infeasibleControlFailures == 0
      && report.counts.oracleVerdictDisagreements == 0
      && report.counts.oracleScoreDisagreements == 0
      && report.counts.oracleSelectionDisagreements == 0 ? 0 : 1)

default:
  fail("unknown command \(command)")
}
