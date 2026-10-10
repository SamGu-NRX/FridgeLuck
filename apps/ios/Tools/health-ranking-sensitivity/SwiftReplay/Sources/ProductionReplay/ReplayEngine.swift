import Foundation

// Replay-side experiment engine (hand-written). NOT part of the byte-parity
// claim: that claim covers only the marker regions in VendoredScoring.swift.
//
// Responsibilities:
//   * decode the frozen matrix and the committed perturbation bounds,
//   * evaluate every recipe x profile through the VENDORED production functions
//     (HealthScoringServiceReplay.replayScore / replayReasoning and
//     RecipeRepositoryReplay.sharedRankingScore / rankingReasons),
//   * perturb ONLY nutrition/portion inputs per the committed bounds (seeded
//     SplitMix64, per-field independent draws, exact zeros preserved),
//   * write raw and aggregate JSON outputs; every failure is recorded in the
//     run metadata, never dropped.
//
// The "indicator" values below exist ONLY to label which production threshold
// flipped on a given draw. All scores, ratings, labels, and strings reported as
// results come from the vendored production code.

public enum ReplayEngineError: Error, CustomStringConvertible {
  case missingInput(String)
  case badBoundsRef(String)
  case unexpected(String)

  public var description: String {
    switch self {
    case .missingInput(let p): return "missing or unreadable input: \(p)"
    case .badBoundsRef(let s): return "unknown bounds reference: \(s)"
    case .unexpected(let s): return "unexpected state: \(s)"
    }
  }
}

// MARK: - Input decoding

public struct MatrixMacros: Codable {
  public var calories: Double
  public var proteinG: Double
  public var carbsG: Double
  public var fatG: Double
  public var fiberG: Double
  public var sugarG: Double
  public var sodiumMg: Double

  enum CodingKeys: String, CodingKey {
    case calories
    case proteinG = "protein_g"
    case carbsG = "carbs_g"
    case fatG = "fat_g"
    case fiberG = "fiber_g"
    case sugarG = "sugar_g"
    case sodiumMg = "sodium_mg"
  }
}

public struct MatrixRecipe: Codable {
  public var id: String
  public var title: String
  public var purpose: String
  public var timeMinutes: Int
  public var tags: [String]
  public var matchedRequired: Int
  public var totalRequired: Int
  public var matchedOptional: Int
  public var missingRequiredCount: Int
  public var personalScore: Double
  public var macrosPerServing: MatrixMacros
  public var notes: String?

  enum CodingKeys: String, CodingKey {
    case id, title, purpose, tags, notes
    case timeMinutes = "time_minutes"
    case matchedRequired = "matched_required"
    case totalRequired = "total_required"
    case matchedOptional = "matched_optional"
    case missingRequiredCount = "missing_required_count"
    case personalScore = "personal_score"
    case macrosPerServing = "macros_per_serving"
  }
}

public struct MatrixProfile: Codable {
  public var id: String
  public var name: String
  public var goal: String
  public var dailyCalories: Int?
  public var proteinPct: Double
  public var carbsPct: Double
  public var fatPct: Double

  enum CodingKeys: String, CodingKey {
    case id, name, goal
    case dailyCalories = "daily_calories"
    case proteinPct = "protein_pct"
    case carbsPct = "carbs_pct"
    case fatPct = "fat_pct"
  }
}

public struct FrozenMatrix: Codable {
  public var schemaVersion: Int
  public var baseCommit: String
  public var profiles: [MatrixProfile]
  public var recipes: [MatrixRecipe]

  enum CodingKeys: String, CodingKey {
    case profiles, recipes
    case schemaVersion = "schema_version"
    case baseCommit = "base_commit"
  }
}

public struct NutrientBounds: Codable {
  public var calories: Double
  public var protein: Double
  public var carbs: Double
  public var fat: Double
  public var fiber: Double
  public var sugar: Double
  public var sodium: Double
}

public struct Envelope: Codable {
  public var nutrientsPct: NutrientBounds
  public var portionScalePct: Double

  enum CodingKeys: String, CodingKey {
    case nutrientsPct = "nutrients_pct"
    case portionScalePct = "portion_scale_pct"
  }
}

/// Decode-only: the committed bounds file describes arms; we never encode it.
public struct ArmSpec: Decodable {
  public var id: String
  public var description: String
  public var nutrientBoundsRef: String?
  public var portionScaleRef: String?
  public var draws: Int
  public var stress: Bool

  enum CodingKeys: String, CodingKey {
    case id, description, draws, stress
    case nutrientBounds = "nutrient_bounds"
    case portionScale = "portion_scale"
  }

  public init(
    id: String, description: String, nutrientBoundsRef: String?, portionScaleRef: String?,
    draws: Int, stress: Bool
  ) {
    self.id = id
    self.description = description
    self.nutrientBoundsRef = nutrientBoundsRef
    self.portionScaleRef = portionScaleRef
    self.draws = draws
    self.stress = stress
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    description = try c.decode(String.self, forKey: .description)
    nutrientBoundsRef = try c.decodeIfPresent(String.self, forKey: .nutrientBounds)
    portionScaleRef = try c.decodeIfPresent(String.self, forKey: .portionScale)
    draws = try c.decode(Int.self, forKey: .draws)
    stress = try c.decodeIfPresent(Bool.self, forKey: .stress) ?? false
  }
}

public struct BoundsFile: Decodable {
  public var drawSeed: UInt64
  public var plausible: Envelope
  public var stress: Envelope
  public var arms: [ArmSpec]

  enum CodingKeys: String, CodingKey {
    case plausible, stress, arms
    case drawSeed = "draw_seed"
  }
}

// MARK: - Deterministic RNG (SplitMix64 + FNV-1a seeding)

struct SplitMix64 {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in [-1, 1) from 52 random bits.
  mutating func uniformPlusMinus() -> Double {
    Double(next() >> 11) / 9_007_199_254_740_992.0 * 2.0 - 1.0
  }
}

func fnv1a(_ s: String) -> UInt64 {
  var h: UInt64 = 0xCBF2_9CE4_8422_2325
  for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x1_0000_0001_B3 }
  return h
}

// MARK: - Evaluation through the vendored production code

public struct EvalRecord: Codable, Equatable {
  public var recipeId: String
  public var rank: Int
  public var rating: Int
  public var label: String
  public var reasoning: String
  public var rankingScore: Double
  public var rankingScoreBits: String
  public var rankingReasons: [String]

  enum CodingKeys: String, CodingKey {
    case rank, rating, label, reasoning
    case recipeId = "recipe_id"
    case rankingScore = "ranking_score"
    case rankingScoreBits = "ranking_score_bits"
    case rankingReasons = "ranking_reasons"
  }
}

struct RowResult {
  var row: MatrixRecipe
  var score: HealthScore
  var ranking: Double
  var reasons: [String]
}

func makeProfile(_ p: MatrixProfile) -> HealthProfile {
  guard let goal = HealthGoal(rawValue: p.goal) else {
    fatalError("unknown goal in frozen matrix: \(p.goal)")
  }
  return HealthProfile(
    displayName: "replay",
    age: nil,
    goal: goal,
    dailyCalories: p.dailyCalories,
    proteinPct: p.proteinPct,
    carbsPct: p.carbsPct,
    fatPct: p.fatPct,
    dietaryRestrictions: "[]",
    allergenIngredientIds: "[]",
    updatedAt: nil
  )
}

func makeMacros(_ m: MatrixMacros) -> RecipeMacros {
  RecipeMacros(
    caloriesPerServing: m.calories,
    proteinPerServing: m.proteinG,
    carbsPerServing: m.carbsG,
    fatPerServing: m.fatG,
    fiberPerServing: m.fiberG,
    sugarPerServing: m.sugarG,
    sodiumPerServing: m.sodiumMg
  )
}

func makeRecipe(_ r: MatrixRecipe) -> Recipe {
  Recipe(
    id: nil,
    title: r.id,
    timeMinutes: r.timeMinutes,
    servings: 1,
    instructions: "",
    tags: RecipeTags(matrixNames: r.tags).rawValue,
    source: .bundled,
    createdAt: nil
  )
}

extension RecipeTags {
  /// Maps the frozen matrix's tag-name strings through the production tag table.
  init(matrixNames: [String]) {
    var tags: RecipeTags = []
    for name in matrixNames {
      if let pair = Self.allTags.first(where: { $0.0 == name }) {
        tags.insert(pair.1)
      }
    }
    self = tags
  }
}

/// Evaluates rows through the vendored production functions and applies the
/// production sort (rankingScore desc, missingRequiredCount asc, timeMinutes
/// asc) with a final input-order tiebreak documented as a replay-side
/// determinism guard (Swift's sort is not stable for full ties).
func evaluateRows(_ rows: [MatrixRecipe], profile: MatrixProfile) -> [EvalRecord] {
  let hp = makeProfile(profile)
  var results: [RowResult] = rows.map { r in
    let m = makeMacros(r.macrosPerServing)
    let recipe = makeRecipe(r)
    let scorer = HealthScoringServiceReplay()
    let score = scorer.replayScore(macros: m, profile: hp)
    let ranking = RecipeRepositoryReplay.sharedRankingScore(
      recipe: recipe,
      matchedRequired: r.matchedRequired,
      totalRequired: r.totalRequired,
      matchedOptional: r.matchedOptional,
      missingRequiredCount: r.missingRequiredCount,
      macros: m,
      healthScore: score,
      personalScore: r.personalScore,
      profile: hp
    )
    let reasons = RecipeRepositoryReplay.rankingReasons(
      recipe: recipe,
      missingRequiredCount: r.missingRequiredCount,
      macros: m,
      healthScore: score,
      profile: hp
    )
    return RowResult(row: r, score: score, ranking: ranking, reasons: reasons)
  }

  results.sort { lhs, rhs in
    if lhs.ranking == rhs.ranking {
      if lhs.row.missingRequiredCount == rhs.row.missingRequiredCount {
        if lhs.row.timeMinutes == rhs.row.timeMinutes {
          return false  // stable: keep input order (replay-side determinism guard)
        }
        return lhs.row.timeMinutes < rhs.row.timeMinutes
      }
      return lhs.row.missingRequiredCount < rhs.row.missingRequiredCount
    }
    return lhs.ranking > rhs.ranking
  }

  return results.enumerated().map { idx, res in
    EvalRecord(
      recipeId: res.row.id,
      rank: idx + 1,
      rating: res.score.rating,
      label: res.score.label,
      reasoning: res.score.reasoning,
      rankingScore: res.ranking,
      rankingScoreBits: String(res.ranking.bitPattern),
      rankingReasons: res.reasons
    )
  }
}

// MARK: - Runner-side threshold indicators (flip LABELS only)

func indicators(for m: RecipeMacros, hp: HealthProfile, row: MatrixRecipe) -> [String: String] {
  var out: [String: String] = [:]
  if let target = hp.dailyCalories {
    let ratio = m.caloriesPerServing / (Double(target) / 3.0)
    let bucket: String
    if ratio >= 0.7 && ratio <= 1.1 { bucket = "30" }
    else if ratio >= 0.5 && ratio < 0.7 { bucket = "20" }
    else if ratio >= 1.1 && ratio < 1.4 { bucket = "15" }
    else { bucket = "5" }
    out["calorie_bucket"] = bucket
  }
  out["fiber_bonus"] = m.fiberPerServing >= 5 ? "on" : "off"
  out["sugar_bonus"] = m.sugarPerServing <= 10 ? "on" : "off"
  out["sodium_bonus"] = m.sodiumPerServing <= 600 ? "on" : "off"
  out["ranking_high_protein"] =
    (row.tags.contains("high_protein") || m.proteinPerServing >= 24) ? "on" : "off"
  switch hp.goal {
  case .weightLoss:
    out["goal_band"] = m.caloriesPerServing <= 550 ? "on" : "off"
  case .maintenance:
    out["goal_band"] =
      (m.caloriesPerServing >= 450 && m.caloriesPerServing <= 750) ? "on" : "off"
  case .muscleGain, .general:
    break
  }
  let split = m.macroSplit
  out["reasoning_protein_band"] =
    split.proteinPct > 0.30 ? "high" : (split.proteinPct > 0.25 ? "good" : "none")
  out["reasoning_cal_band"] =
    m.caloriesPerServing < 350 ? "light" : (m.caloriesPerServing > 700 ? "hearty" : "mid")
  return out
}

// MARK: - Perturbation

struct ResolvedArm {
  var spec: ArmSpec
  var nutrients: NutrientBounds?  // percent values
  var portionPct: Double?
}

func resolveArms(_ bounds: BoundsFile) throws -> [ResolvedArm] {
  try bounds.arms.map { spec in
    var arm = ResolvedArm(spec: spec, nutrients: nil, portionPct: nil)
    if let ref = spec.nutrientBoundsRef {
      switch ref {
      case "plausible.nutrients_pct": arm.nutrients = bounds.plausible.nutrientsPct
      case "stress.nutrients_pct": arm.nutrients = bounds.stress.nutrientsPct
      default: throw ReplayEngineError.badBoundsRef(ref)
      }
    }
    if let ref = spec.portionScaleRef {
      switch ref {
      case "plausible.portion_scale_pct": arm.portionPct = bounds.plausible.portionScalePct
      case "stress.portion_scale_pct": arm.portionPct = bounds.stress.portionScalePct
      default: throw ReplayEngineError.badBoundsRef(ref)
      }
    }
    return arm
  }
}

func perturbed(_ base: MatrixMacros, arm: ResolvedArm, seedMaterial: String, drawSeed: UInt64)
  -> MatrixMacros
{
  var m = base
  if let nutrients = arm.nutrients {
    func factor(_ pct: Double, _ field: String) -> Double {
      var rng = SplitMix64(seed: drawSeed ^ fnv1a(seedMaterial + "|" + field))
      let u = rng.uniformPlusMinus()  // [-1, 1)
      return 1.0 + (pct / 100.0) * u
    }
    m.calories = base.calories * factor(nutrients.calories, "calories")
    m.proteinG = base.proteinG * factor(nutrients.protein, "protein")
    m.carbsG = base.carbsG * factor(nutrients.carbs, "carbs")
    m.fatG = base.fatG * factor(nutrients.fat, "fat")
    m.fiberG = base.fiberG * factor(nutrients.fiber, "fiber")
    m.sugarG = base.sugarG * factor(nutrients.sugar, "sugar")
    m.sodiumMg = base.sodiumMg * factor(nutrients.sodium, "sodium")
  }
  if let portionPct = arm.portionPct {
    var rng = SplitMix64(seed: drawSeed ^ fnv1a(seedMaterial + "|portion"))
    let s = 1.0 + (portionPct / 100.0) * rng.uniformPlusMinus()
    m.calories *= s
    m.proteinG *= s
    m.carbsG *= s
    m.fatG *= s
    m.fiberG *= s
    m.sugarG *= s
    m.sodiumMg *= s
  }
  return m
}

// MARK: - Aggregates

public struct ArmProfileSummary: Codable {
  public var arm: String
  public var stress: Bool
  public var profile: String
  public var draws: Int
  public var rankMovingDraws: Int
  public var rankMovesTotal: Int
  public var ratingFlipsTotal: Int
  public var ratingFlipsByRecipe: [String: Int]
  public var reasoningChangesTotal: Int
  public var reasoningChangeExamples: [String]
  public var boundaryFlips: [String: Int]
  public var pairwiseOverlappingIntervals: Int
  public var pairwiseTotal: Int
  public var pairwiseSkippedIntervals: Int
  public var firstRankSwaps: [String]
  public var failures: [String]
  public var wallMs: Double

  enum CodingKeys: String, CodingKey {
    case arm, stress, profile, draws, failures
    case rankMovingDraws = "rank_moving_draws"
    case rankMovesTotal = "rank_moves_total"
    case ratingFlipsTotal = "rating_flips_total"
    case ratingFlipsByRecipe = "rating_flips_by_recipe"
    case reasoningChangesTotal = "reasoning_changes_total"
    case reasoningChangeExamples = "reasoning_change_examples"
    case boundaryFlips = "boundary_flips"
    case pairwiseOverlappingIntervals = "pairwise_overlapping_intervals"
    case pairwiseTotal = "pairwise_total"
    case pairwiseSkippedIntervals = "pairwise_skipped_intervals"
    case firstRankSwaps = "first_rank_swaps"
    case wallMs = "wall_ms"
  }
}

/// Aggregates over the first `draws` draws of one arm-profile cell, also
/// recorded as raw output so the report verifier can recompute them from the
/// committed samples alone.
public struct WindowSummary: Codable {
  public var arm: String
  public var profile: String
  public var draws: Int
  public var rankMovingDraws: Int
  public var rankMovesTotal: Int
  public var ratingFlipsTotal: Int
  public var reasoningChangesTotal: Int
  public var boundaryFlips: [String: Int]
  public var pairwiseOverlappingIntervals: Int
  public var pairwiseTotal: Int
  public var pairwiseSkippedIntervals: Int

  enum CodingKeys: String, CodingKey {
    case arm, profile, draws
    case rankMovingDraws = "rank_moving_draws"
    case rankMovesTotal = "rank_moves_total"
    case ratingFlipsTotal = "rating_flips_total"
    case reasoningChangesTotal = "reasoning_changes_total"
    case boundaryFlips = "boundary_flips"
    case pairwiseOverlappingIntervals = "pairwise_overlapping_intervals"
    case pairwiseTotal = "pairwise_total"
    case pairwiseSkippedIntervals = "pairwise_skipped_intervals"
  }
}

public struct RunMeta: Codable {
  public var baseCommit: String
  public var drawSeed: UInt64
  public var recipeCount: Int
  public var profileCount: Int
  public var armSummaries: [ArmProfileSummary]
  public var windowSummaries: [WindowSummary]
  public var controlVerifiedNotes: [String]
  public var failureCount: Int
  public var runtimeNote: String

  enum CodingKeys: String, CodingKey {
    case baseCommit = "base_commit"
    case drawSeed = "draw_seed"
    case recipeCount = "recipe_count"
    case profileCount = "profile_count"
    case armSummaries = "arm_summaries"
    case windowSummaries = "window_summaries"
    case controlVerifiedNotes = "control_verified_notes"
    case failureCount = "failure_count"
    case runtimeNote = "runtime_note"
  }
}

func writeJSON<T: Encodable>(_ value: T, to path: URL) throws {
  let enc = JSONEncoder()
  enc.outputFormatting = [.prettyPrinted, .sortedKeys]
  var data = try enc.encode(value)
  data.append(0x0A)  // trailing newline
  try data.write(to: path)
}

/// Compact variant for the larger per-draw sample files.
func writeJSONCompact<T: Encodable>(_ value: T, to path: URL) throws {
  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys]
  var data = try enc.encode(value)
  data.append(0x0A)
  try data.write(to: path)
}

/// Overlapping-pair count over per-recipe score intervals.
func pairwiseIntervalStats(
  _ minScore: [String: Double], _ maxScore: [String: Double], _ ids: [String]
) -> (overlaps: Int, pairs: Int, skipped: Int) {
  var overlaps = 0
  var pairs = 0
  var skipped = 0
  for i in 0..<ids.count {
    for j in (i + 1)..<ids.count {
      guard
        let loI = minScore[ids[i]], let hiI = maxScore[ids[i]],
        let loJ = minScore[ids[j]], let hiJ = maxScore[ids[j]]
      else {
        skipped += 1  // interval missing => failures already recorded above
        continue
      }
      pairs += 1
      if max(loI, loJ) <= min(hiI, hiJ) { overlaps += 1 }
    }
  }
  return (overlaps, pairs, skipped)
}

// MARK: - Output container types

public struct ControlOutput: Codable {
  public var profile: String
  public var records: [EvalRecord]

  enum CodingKeys: String, CodingKey {
    case records
    case profile = "profile_id"
  }
}

/// Sample records additionally carry the perturbed macros actually used, so
/// every window aggregate is recomputable from committed raw outputs alone.
public struct SampleRecord: Codable {
  public var recipeId: String
  public var rank: Int
  public var rating: Int
  public var label: String
  public var reasoning: String
  public var rankingScore: Double
  public var rankingScoreBits: String
  public var rankingReasons: [String]
  public var macrosUsed: MatrixMacros

  enum CodingKeys: String, CodingKey {
    case rank, rating, label, reasoning
    case recipeId = "recipe_id"
    case rankingScore = "ranking_score"
    case rankingScoreBits = "ranking_score_bits"
    case rankingReasons = "ranking_reasons"
    case macrosUsed = "macros_used"
  }

  init(record: EvalRecord, macros: MatrixMacros) {
    recipeId = record.recipeId
    rank = record.rank
    rating = record.rating
    label = record.label
    reasoning = record.reasoning
    rankingScore = record.rankingScore
    rankingScoreBits = record.rankingScoreBits
    rankingReasons = record.rankingReasons
    macrosUsed = macros
  }
}

public struct SampleDraw: Codable {
  public var draw: Int
  public var records: [SampleRecord]

  enum CodingKeys: String, CodingKey { case draw, records }
}

public struct RawSampleOutput: Codable {
  public var arm: String
  public var profile: String
  public var windowDraws: Int
  public var draws: [SampleDraw]

  enum CodingKeys: String, CodingKey {
    case draws
    case arm = "arm_id"
    case profile = "profile_id"
    case windowDraws = "window_draws"
  }
}

// MARK: - Public entry points

public enum ReplayEngine {
  public static func loadJSON<T: Decodable>(_ type: T.Type, path: String) throws -> T {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      throw ReplayEngineError.missingInput(path)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
  }

  /// Control arm: evaluate all recipes for one profile with unchanged inputs.
  public static func controlRecords(matrix: FrozenMatrix, profile: MatrixProfile) -> [EvalRecord] {
    evaluateRows(matrix.recipes, profile: profile)
  }

  /// Runs the full perturbation experiment and writes outputs into `outputDir`.
  @discardableResult
  public static func runExperiment(
    matrix: FrozenMatrix,
    bounds: BoundsFile,
    outputDir: String,
    windowDraws: Int = 10
  ) throws -> RunMeta {
    let fm = FileManager.default
    try fm.createDirectory(atPath: outputDir + "/raw", withIntermediateDirectories: true)

    var summaries: [ArmProfileSummary] = []
    var windowSummaries: [WindowSummary] = []
    var notes: [String] = []
    var failureCount = 0

    // Control arm (per profile): full records.
    for profile in matrix.profiles {
      let records = controlRecords(matrix: matrix, profile: profile)
      let path = "\(outputDir)/raw/control__\(profile.id).json"
      try writeJSON(
        ControlOutput(profile: profile.id, records: records),
        to: URL(fileURLWithPath: path))
      notes.append("control written for \(profile.id) (\(records.count) recipes)")
    }

    let arms = try resolveArms(bounds)

    for arm in arms where !(arm.nutrients == nil && arm.portionPct == nil) {
      for profile in matrix.profiles {
        let started = Date()
        let hp = makeProfile(profile)
        let control = controlRecords(matrix: matrix, profile: profile)
        var controlByRecipe: [String: EvalRecord] = [:]
        for rec in control { controlByRecipe[rec.recipeId] = rec }
        var controlIndicators: [String: [String: String]] = [:]
        for r in matrix.recipes {
          controlIndicators[r.id] = indicators(
            for: makeMacros(r.macrosPerServing), hp: hp, row: r)
        }

        var rankMovingDraws = 0
        var rankMovesTotal = 0
        var ratingFlipsTotal = 0
        var ratingFlipsByRecipe: [String: Int] = [:]
        var reasoningChangesTotal = 0
        var reasoningChangeExamples: [String] = []
        var boundaryFlips: [String: Int] = [:]
        var firstRankSwaps: [String] = []
        var failures: [String] = []
        var minScore: [String: Double] = [:]
        var maxScore: [String: Double] = [:]
        var rawSample: [SampleDraw] = []
        // Window accumulators mirror the full-run ones over the first
        // `windowDraws` draws; they are recomputed from raw samples by the
        // report verifier.
        var wRankMovingDraws = 0
        var wRankMovesTotal = 0
        var wRatingFlipsTotal = 0
        var wReasoningChangesTotal = 0
        var wBoundaryFlips: [String: Int] = [:]
        var wMinScore: [String: Double] = [:]
        var wMaxScore: [String: Double] = [:]

        for draw in 0..<arm.spec.draws {
          // Perturb and evaluate every recipe this draw.
          var perturbedRows: [MatrixRecipe] = []
          perturbedRows.reserveCapacity(matrix.recipes.count)
          var perturbedMacrosByRecipe: [String: MatrixMacros] = [:]
          for (idx, r) in matrix.recipes.enumerated() {
            let seedMaterial = "\(arm.spec.id)|\(profile.id)|\(draw)|\(idx)"
            let m = perturbed(
              r.macrosPerServing, arm: arm, seedMaterial: seedMaterial,
              drawSeed: bounds.drawSeed)
            var copy = r
            copy.macrosPerServing = m
            perturbedRows.append(copy)
            perturbedMacrosByRecipe[r.id] = m
          }
          let records = evaluateRows(perturbedRows, profile: profile)
          var recordByRecipe: [String: EvalRecord] = [:]
          for rec in records {
            if recordByRecipe[rec.recipeId] != nil {
              throw ReplayEngineError.unexpected(
                "duplicate recipe id in draw output: \(rec.recipeId)")
            }
            recordByRecipe[rec.recipeId] = rec
          }

          // Aggregate.
          var anyRankMove = false
          for rec in records {
            guard let ctrl = controlByRecipe[rec.recipeId] else {
              throw ReplayEngineError.unexpected("recipe \(rec.recipeId) missing from control")
            }
            let m = makeMacros(perturbedMacrosByRecipe[rec.recipeId]!)
            if !rec.rankingScore.isFinite {
              failures.append(
                "draw=\(draw) recipe=\(rec.recipeId) non-finite ranking score")
              continue
            }
            minScore[rec.recipeId] = min(minScore[rec.recipeId] ?? .infinity, rec.rankingScore)
            maxScore[rec.recipeId] = max(maxScore[rec.recipeId] ?? -.infinity, rec.rankingScore)
            if draw < windowDraws {
              wMinScore[rec.recipeId] = min(wMinScore[rec.recipeId] ?? .infinity, rec.rankingScore)
              wMaxScore[rec.recipeId] = max(wMaxScore[rec.recipeId] ?? -.infinity, rec.rankingScore)
            }

            if rec.rank != ctrl.rank {
              anyRankMove = true
              rankMovesTotal += 1
              if draw < windowDraws { wRankMovesTotal += 1 }
              if firstRankSwaps.count < 12 {
                let nowAbove = rec.rank > 1
                  ? (recordByRecipe.first { $0.value.rank == rec.rank - 1 }?.value.recipeId ?? "?")
                  : "top"
                firstRankSwaps.append(
                  "draw=\(draw) \(rec.recipeId) rank \(ctrl.rank)->\(rec.rank) (now directly below \(nowAbove))")
              }
            }
            if rec.rating != ctrl.rating {
              ratingFlipsTotal += 1
              ratingFlipsByRecipe[rec.recipeId, default: 0] += 1
              if draw < windowDraws { wRatingFlipsTotal += 1 }
            }
            if rec.reasoning != ctrl.reasoning {
              reasoningChangesTotal += 1
              if draw < windowDraws { wReasoningChangesTotal += 1 }
              if reasoningChangeExamples.count < 10 {
                reasoningChangeExamples.append(
                  "draw=\(draw) recipe=\(rec.recipeId): '\(ctrl.reasoning)' -> '\(rec.reasoning)'")
              }
            }
            let row = matrix.recipes.first(where: { $0.id == rec.recipeId })!
            let nowInd = indicators(for: m, hp: hp, row: row)
            let ctrlInd = controlIndicators[rec.recipeId]!
            for (key, value) in nowInd where ctrlInd[key] != value {
              boundaryFlips["\(key):\(ctrlInd[key] ?? "?")->\(value)"] =
                (boundaryFlips["\(key):\(ctrlInd[key] ?? "?")->\(value)"] ?? 0) + 1
              if draw < windowDraws {
                wBoundaryFlips["\(key):\(ctrlInd[key] ?? "?")->\(value)"] =
                  (wBoundaryFlips["\(key):\(ctrlInd[key] ?? "?")->\(value)"] ?? 0) + 1
              }
            }
          }
          if anyRankMove { rankMovingDraws += 1 }
          if anyRankMove && draw < windowDraws { wRankMovingDraws += 1 }

          if draw < windowDraws {
            rawSample.append(
              SampleDraw(
                draw: draw,
                records: records.map { rec in
                  SampleRecord(record: rec, macros: perturbedMacrosByRecipe[rec.recipeId]!)
                }))
          }
        }

        // Pairwise interval overlaps (Monte-Carlo min/max per recipe),
        // full run and first-window variant (the verifier recomputes the
        // window variant from the committed raw samples).
        let ids = matrix.recipes.map(\.id)
        let (overlaps, pairs, skippedPairs) = pairwiseIntervalStats(minScore, maxScore, ids)
        let windowStats = pairwiseIntervalStats(wMinScore, wMaxScore, ids)

        let wallMs = -started.timeIntervalSinceNow * 1000.0
        windowSummaries.append(
          WindowSummary(
            arm: arm.spec.id,
            profile: profile.id,
            draws: min(windowDraws, arm.spec.draws),
            rankMovingDraws: wRankMovingDraws,
            rankMovesTotal: wRankMovesTotal,
            ratingFlipsTotal: wRatingFlipsTotal,
            reasoningChangesTotal: wReasoningChangesTotal,
            boundaryFlips: wBoundaryFlips,
            pairwiseOverlappingIntervals: windowStats.overlaps,
            pairwiseTotal: windowStats.pairs,
            pairwiseSkippedIntervals: windowStats.skipped))
        summaries.append(
          ArmProfileSummary(
            arm: arm.spec.id,
            stress: arm.spec.stress,
            profile: profile.id,
            draws: arm.spec.draws,
            rankMovingDraws: rankMovingDraws,
            rankMovesTotal: rankMovesTotal,
            ratingFlipsTotal: ratingFlipsTotal,
            ratingFlipsByRecipe: ratingFlipsByRecipe,
            reasoningChangesTotal: reasoningChangesTotal,
            reasoningChangeExamples: reasoningChangeExamples,
            boundaryFlips: boundaryFlips,
            pairwiseOverlappingIntervals: overlaps,
            pairwiseTotal: pairs,
            pairwiseSkippedIntervals: skippedPairs,
            firstRankSwaps: firstRankSwaps,
            failures: failures,
            wallMs: (wallMs * 1000).rounded() / 1000
          ))
        failureCount += failures.count

        if !rawSample.isEmpty {
          try writeJSONCompact(
            RawSampleOutput(
              arm: arm.spec.id,
              profile: profile.id,
              windowDraws: min(windowDraws, arm.spec.draws),
              draws: rawSample),
            to: URL(fileURLWithPath: "\(outputDir)/raw/sample__\(arm.spec.id)__\(profile.id).json"))
        }
      }
    }

    let meta = RunMeta(
      baseCommit: matrix.baseCommit,
      drawSeed: bounds.drawSeed,
      recipeCount: matrix.recipes.count,
      profileCount: matrix.profiles.count,
      armSummaries: summaries,
      windowSummaries: windowSummaries,
      controlVerifiedNotes: notes,
      failureCount: failureCount,
      runtimeNote: "Swift replay, Linux x86_64, deterministic SplitMix64 draws"
    )
    try writeJSON(meta, to: URL(fileURLWithPath: "\(outputDir)/run_meta.json"))
    return meta
  }
}
