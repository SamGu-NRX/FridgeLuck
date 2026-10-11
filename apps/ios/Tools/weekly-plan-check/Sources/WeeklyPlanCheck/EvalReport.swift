import Foundation
import WeeklyPlanCore

// MARK: - Eval report
//
// A run produces a machine-readable report. Deterministic fields (counts,
// scores, agreement tallies) are verified by `--verify-report`; timing fields
// are informational only and never verified, because they vary by host.

public struct WeeklyPlanEvalReport: Codable, Equatable {
  public struct Counts: Codable, Equatable {
    public var states: Int = 0
    public var feasible: Int = 0
    public var infeasible: Int = 0
    public var substitutionsUsed: Int = 0
    public var repetitionUsed: Int = 0
    public var hardExclusionViolations: Int = 0
    public var oraclePairsChecked: Int = 0
    public var oracleVerdictDisagreements: Int = 0
    public var oracleScoreDisagreements: Int = 0
    public var oracleSelectionDisagreements: Int = 0
    public var infeasibleControlFailures: Int = 0
  }

  public struct ObjectiveStats: Codable, Equatable {
    public var minFeasibleScore: Double?
    public var medianFeasibleScore: Double?
    public var maxFeasibleScore: Double?
    public var meanShortageRowsFeasible: Double?

    init(scores: [Double], shortageRows: [Int]) {
      let sortedScores = scores.sorted()
      self.minFeasibleScore = sortedScores.first
      self.maxFeasibleScore = sortedScores.last
      self.medianFeasibleScore =
        sortedScores.isEmpty
          ? nil
          : sortedScores.count % 2 == 1
            ? sortedScores[sortedScores.count / 2]
            : (sortedScores[sortedScores.count / 2 - 1] + sortedScores[sortedScores.count / 2]) / 2
      self.meanShortageRowsFeasible =
        shortageRows.isEmpty
          ? nil : Double(shortageRows.reduce(0, +)) / Double(shortageRows.count)
    }
  }

  public struct Runtime: Codable, Equatable {
    public var engineMillis: Double = 0
    public var oracleMillis: Double = 0
  }

  public var seed: UInt64
  public var statesRequested: Int
  public var counts: Counts
  public var objective: ObjectiveStats
  public var runtime: Runtime
  /// Corpus identity: digest over all fingerprints in generation order.
  public var corpusDigest: String
  public var generatedAt: String

  public static func run(seed: UInt64, count: Int) -> WeeklyPlanEvalReport {
    var generator = HouseholdGenerator(seed: seed)
    let states = generator.generate(count: count)

    var counts = Counts()
    var feasibleScores: [Double] = []
    var shortageRows: [Int] = []
    var fingerprints: [String] = []

    let engineStart = Date()
    for input in states {
      fingerprints.append(WeeklyPlanFingerprint.compute(input))
      let result = WeeklyPlanEngine.plan(input)
      counts.states += 1

      switch result.verdict {
      case .feasible:
        counts.feasible += 1
        feasibleScores.append(result.score)
        // Defensive check: no required consumption row may resolve to an
        // excluded ingredient — the allocator is required to drop those.
        let slotMap = Dictionary(uniqueKeysWithValues: input.slots.map { ($0.id, $0) })
        let planned: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)] = result.assignments.compactMap { a in
          guard let slot = slotMap[a.slotId],
            let recipe = input.recipes.first(where: { $0.id == a.recipeId })
          else { return nil }
          return (slot, recipe)
        }
        let rows = WeeklyPlanConsumption.allocate(
          assignment: planned, stock: input.stockByID, constraints: input.constraints)
        for row in rows where row.isRequired {
          // Exclusions are never waived: a resolved ingredient that is both
          // excluded and actually consumed would be a real violation. A short
          // allowed substitute under an excluded primary is legitimate.
          if input.constraints.excludedIngredientIds.contains(row.resolvedIngredientId),
            row.grams > 0
          {
            counts.hardExclusionViolations += 1
          }
        }
      case .infeasible:
        counts.infeasible += 1
      }

      counts.substitutionsUsed += result.assignments.reduce(0) { $0 + $1.substitutions.count }
      shortageRows.append(result.shortages.count)

      // Repetition use: the same recipe appearing in two or more slots.
      let recipeIds = result.assignments.map(\.recipeId)
      if Set(recipeIds).count < recipeIds.count { counts.repetitionUsed += 1 }

      // Oracle agreement on the exact domain.
      if input.recipes.count <= 6 && input.slots.count <= 3 {
        let oracleResult = WeeklyPlanOracle.plan(input)
        counts.oraclePairsChecked += 1
        let engineFeasible = result.verdict == WeeklyPlanVerdict.feasible
        let oracleFeasible = oracleResult.verdict == WeeklyPlanVerdict.feasible
        if engineFeasible != oracleFeasible {
          counts.oracleVerdictDisagreements += 1
        } else if engineFeasible {
          if abs(result.score - oracleResult.score) > 1e-9 {
            counts.oracleScoreDisagreements += 1
          }
          let engineSelection = Set(result.assignments.map { "\($0.slotId):\($0.recipeId)" })
          let oracleSelection = Set(oracleResult.assignments.map { "\($0.slotId):\($0.recipeId)" })
          if engineSelection != oracleSelection {
            counts.oracleSelectionDisagreements += 1
          }
        }
      }
    }
    let engineEnd = Date()

    // Independent infeasible controls (excluded-ingredient waiver temptation).
    for variant in [
      HouseholdGenerator.waiverTemptation(excluded: 7, sub: 8),
      HouseholdGenerator.waiverTemptation(excluded: 3, sub: 4),
      HouseholdGenerator.waiverTemptation(excluded: 39, sub: 40),
    ] {
      let result = WeeklyPlanEngine.plan(variant)
      if result.verdict == WeeklyPlanVerdict.feasible { counts.infeasibleControlFailures += 1 }
    }

    let digest = fingerprints.joined().digestHex
    return WeeklyPlanEvalReport(
      seed: seed, statesRequested: count, counts: counts,
      objective: ObjectiveStats(scores: feasibleScores, shortageRows: shortageRows),
      runtime: Runtime(engineMillis: engineEnd.timeIntervalSince(engineStart) * 1000),
      corpusDigest: digest, generatedAt: ISO8601DateFormatter().string(from: Date()))
  }

  /// The subset verified by `--verify-report`: everything except runtime and
  /// the generation timestamp.
  public var verifiedFields: WeeklyPlanEvalReport {
    var copy = self
    copy.runtime = Runtime()
    copy.generatedAt = ""
    return copy
  }
}

extension String {
  /// Stable 128-bit digest rendered as hex (two independent 64-bit FNV-style
  /// accumulators). A corpus-identity marker, not a security primitive.
  var digestHex: String {
    var h1: UInt64 = 0xcbf29ce484222325
    var h2: UInt64 = 0x6363636363636363
    for byte in utf8 {
      h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
      h2 = (h2 &+ UInt64(byte)) &* 0x9E3779B97F4A7C15
      h2 ^= h2 >> 29
    }
    return String(format: "%016lx%016lx", h1, h2)
  }
}
