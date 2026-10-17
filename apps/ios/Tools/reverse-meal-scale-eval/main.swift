import Foundation
import GRDB

// next-decisions-v1 scale runner (spec: backend/gemini-agent/evaluation-fixtures/
// next-decisions/next-decisions-spec-v1.md).
//
// Runs the REAL ConfidenceLearningService (cold and devwarm arms) over the frozen
// study evidence, with candidate generation from the REAL RecipeRepository on a
// catalog DB seeded by the REAL BundledDataLoader/Migrations.
//
// The pure producer functions below are a pinned copy from
// apps/ios/Capability/Core/Services/ReverseScanService.swift and
// apps/ios/Capability/Core/Recognition/ConfidenceRouter.swift at the commit
// recorded in the build record. Their outputs are cross-checked for every case
// by the TypeScript harness (scaleCrossCheck), which recomputes them from the
// exported candidate fields.

let signalKeys = ["reverse_scan.vision_detection", "reverse_scan.recipe_match",
                  "reverse_scan.required_coverage", "reverse_scan.candidate_margin"]
let signalWeights: [Double] = [0.32, 0.30, 0.23, 0.15]
let signalReasons = ["ingredient detection", "recipe match", "required ingredient coverage", "candidate ambiguity"]

struct EvaluationFailure: Error, CustomStringConvertible {
  let description: String
}
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw EvaluationFailure(description: message) }
}

// MARK: - Frozen inputs

struct EvidenceRow: Decodable {
  let case_id: String
  let detections: [[Double]]  // [catalog_ingredient_id, confidence]
}
struct ReplayEpisode: Decodable {
  let case_id: String
  let action: String
  let reward: Double
}
struct ReplayFile: Decodable {
  let version: String
  let episodes: [ReplayEpisode]
}

// MARK: - Producer math (pinned copies; see file header)

struct DetectionView {
  let ingredientId: Int64
  let confidence: Double  // stored Float32 precision; delivered as Double
}

// ConfidenceRouter (ConfidenceRouter.swift): confirm band floor 0.45; possible
// (< 0.45) is excluded from the search set.
func routedSearchDetections(_ detections: [DetectionView]) -> [DetectionView] {
  detections.filter { $0.confidence >= 0.45 }
}

// ReverseScanService.averageConfidence(for:): mean over ALL detections.
func averageConfidence(for detections: [DetectionView]) -> Double {
  guard !detections.isEmpty else { return 0 }
  let sum = detections.reduce(0.0) { partial, detection in
    partial + max(0, min(detection.confidence, 1.0))
  }
  return sum / Double(detections.count)
}

// ReverseScanService.dedupeRecipes(_:): first occurrence per recipe id.
func dedupeRecipes(_ recipes: [ScoredRecipe]) -> [ScoredRecipe] {
  var seen = Set<Int64>()
  var deduped: [ScoredRecipe] = []
  for recipe in recipes {
    guard let recipeID = recipe.id else { continue }
    guard seen.insert(recipeID).inserted else { continue }
    deduped.append(recipe)
  }
  return deduped
}

// ReverseScanService.confidenceScore(for:overallDetectionConfidence:detectedIngredientCount:).
func confidenceScore(
  for scoredRecipe: ScoredRecipe,
  overallDetectionConfidence: Double,
  detectedIngredientCount: Int
) -> Double {
  let requiredCoverage =
    Double(scoredRecipe.matchedRequired) / Double(max(scoredRecipe.totalRequired, 1))
  let missingPenalty = Double(scoredRecipe.missingRequiredCount) * 0.18
  let optionalCoverage =
    Double(scoredRecipe.matchedOptional) / Double(max(detectedIngredientCount, 1))
  let rawScore =
    (requiredCoverage * 0.62)
    + (overallDetectionConfidence * 0.24)
    + (optionalCoverage * 0.14)
    - missingPenalty
  return max(0, min(rawScore, 1.0))
}

struct ProducedCandidate {
  let recipeId: Int64
  let confidenceScore: Double
  let matchedRequired: Int
  let totalRequired: Int
  let missingRequiredCount: Int
  let matchedOptional: Int
  let rankingScore: Double
  let matchTier: String
}

// ReverseScanService.confidenceSignals + confidenceHardFailReasons projection.
func produce(
  detections: [DetectionView], candidates: [ProducedCandidate]
) -> (signals: [ConfidenceSignalInput], hardFailReasons: [String]) {
  let overall = averageConfidence(for: detections)
  let top = candidates.first
  let topScore = top?.confidenceScore ?? 0
  let requiredCoverage = top.map { Double($0.matchedRequired) / Double(max($0.totalRequired, 1)) } ?? 0
  let marginScore: Double
  if candidates.count >= 2 {
    let margin = max(0, candidates[0].confidenceScore - candidates[1].confidenceScore)
    marginScore = max(0, min(0.5 + margin, 1.0))
  } else if candidates.count == 1 {
    marginScore = 0.82
  } else {
    marginScore = 0
  }
  let values = [overall, topScore, requiredCoverage, marginScore]
  let signals = signalKeys.indices.map {
    ConfidenceSignalInput(key: signalKeys[$0], rawScore: values[$0], weight: signalWeights[$0], reason: signalReasons[$0])
  }
  var hardFailReasons: [String]
  if top == nil {
    hardFailReasons = ["No confident recipe candidate."]
  } else if top!.missingRequiredCount > 2 {
    hardFailReasons = ["Too many required ingredients are missing."]
  } else if candidates.count >= 2,
            candidates[0].confidenceScore - candidates[1].confidenceScore < 0.06 {
    hardFailReasons = ["Top recipe candidates are highly ambiguous."]
  } else {
    hardFailReasons = []
  }
  return (signals, hardFailReasons)
}

// MARK: - Case execution

func canonicalJSON(_ value: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

struct CaseOutcome {
  let caseId: String
  let produced: (signals: [ConfidenceSignalInput], hardFailReasons: [String])
  let candidates: [ProducedCandidate]
  let assessment: ConfidenceAssessment
  let overallDetectionConfidence: Double
  let searchIngredientIds: [Int64]
  let eventCount: Int
}

func makeServices(db: DatabaseQueue) -> (RecipeRepository, HealthScoringService) {
  let nutrition = NutritionService(db: db)
  let health = HealthScoringService(nutritionService: nutrition, db: db)
  let personal = PersonalizationService(db: db)
  let repo = RecipeRepository(
    db: db, nutritionService: nutrition, healthScoringService: health,
    personalizationService: personal)
  return (repo, health)
}

// Executes one case against the given DB: real repository search + real learner
// assess. The assessment phase never writes; eventCount asserts that.
func runCase(
  _ row: EvidenceRow, db: DatabaseQueue, repo: RecipeRepository, health: HealthScoringService,
  expectedEventCount: Int
) throws -> CaseOutcome {
  let learner = ConfidenceLearningService(db: db)
  let detections = row.detections.map {
    DetectionView(ingredientId: Int64($0[0]), confidence: Double(Float($0[1])))
  }
  let searchSet = Set(routedSearchDetections(detections).map(\.ingredientId))
  var candidates: [ProducedCandidate] = []
  if !searchSet.isEmpty {
    let profile = try health.fetchHealthProfile()
    let exact = try repo.findMakeable(with: searchSet, profile: profile, limit: 6)
    let near = try repo.findNearMatch(with: searchSet, profile: profile, maxMissingRequired: 2, limit: 8)
    for scored in dedupeRecipes(exact + near) {
      candidates.append(
        ProducedCandidate(
          recipeId: scored.recipe.id ?? -1,
          confidenceScore: confidenceScore(
            for: scored, overallDetectionConfidence: averageConfidence(for: detections),
            detectedIngredientCount: searchSet.count),
          matchedRequired: scored.matchedRequired,
          totalRequired: scored.totalRequired,
          missingRequiredCount: scored.missingRequiredCount,
          matchedOptional: scored.matchedOptional,
          rankingScore: scored.rankingScore,
          matchTier: scored.matchTier.rawValue))
    }
    candidates.sort {
      if $0.confidenceScore == $1.confidenceScore { return $0.rankingScore > $1.rankingScore }
      return $0.confidenceScore > $1.confidenceScore
    }
  }
  let produced = produce(detections: detections, candidates: candidates)
  let assessment = learner.assess(signals: produced.signals, hardFailReasons: produced.hardFailReasons)
  let eventCount = (try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM confidence_signal_events") }) ?? -1
  try require(eventCount == expectedEventCount,
    "assessment wrote events on \(row.case_id): \(eventCount) != \(expectedEventCount)")
  return CaseOutcome(
    caseId: row.case_id, produced: produced, candidates: candidates, assessment: assessment,
    overallDetectionConfidence: averageConfidence(for: detections),
    searchIngredientIds: searchSet.sorted(), eventCount: eventCount)
}

func outcomeJSON(_ outcome: CaseOutcome) throws -> [String: Any] {
  [
    "case_id": outcome.caseId,
    "overall_detection_confidence": outcome.overallDetectionConfidence,
    "search_ingredient_ids": outcome.searchIngredientIds,
    "signals": outcome.produced.signals.map {
      ["key": $0.key, "rawScore": $0.rawScore, "weight": $0.weight, "reason": $0.reason] as [String: Any]
    },
    "hardFailReasons": outcome.produced.hardFailReasons,
    "assessment": [
      "mode": outcome.assessment.mode.rawValue,
      "overallScore": outcome.assessment.overallScore,
      "deterministicReady": outcome.assessment.deterministicReady,
      "reasons": outcome.assessment.reasons,
      "signals": outcome.assessment.signals.map {
        ["key": $0.key, "rawScore": $0.rawScore, "adjustedScore": $0.adjustedScore,
         "trustMean": $0.trustMean, "trustUncertainty": $0.trustUncertainty,
         "weight": $0.weight, "reason": $0.reason] as [String: Any]
      },
    ],
    "candidates": outcome.candidates.map {
      ["recipe_id": $0.recipeId, "confidence_score": $0.confidenceScore,
       "matched_required": $0.matchedRequired, "total_required": $0.totalRequired,
       "missing_required_count": $0.missingRequiredCount, "matched_optional": $0.matchedOptional,
       "ranking_score": $0.rankingScore, "match_tier": $0.matchTier] as [String: Any]
    },
    "db_event_count": outcome.eventCount,
  ]
}

// MARK: - Replay (devwarm)

// Mirrors ConfidenceLearningService.prior(for:) for the keys in use.
func priorFor(_ key: String) -> (alpha: Double, beta: Double) {
  let normalized = key.lowercased()
  if normalized.contains("vision") { return (6.0, 2.4) }
  if normalized.contains("recipe") { return (4.5, 2.9) }
  return (4.0, 3.0)
}

// Mirrors the real blend in recordOutcome: calibration + 0.55/0.45 mixture.
func replayRewardBlend(reward: Double, signals: [ConfidenceSignalInput],
                       adjusted: [Double]) -> [Double] {
  signals.indices.map { i in
    let calibration = max(0, min(1 - abs(reward - adjusted[i]), 1.0))
    return max(0, min(reward * 0.55 + calibration * 0.45, 1.0))
  }
}

func replay(
  _ replayFile: ReplayFile, evidence: [String: EvidenceRow], db: DatabaseQueue,
  repo: RecipeRepository, health: HealthScoringService
) throws -> Int {
  let learner = ConfidenceLearningService(db: db)
  var expected = [String: (alpha: Double, beta: Double)]()
  var recordedEpisodes = 0
  for episode in replayFile.episodes {
    guard let row = evidence[episode.case_id] else {
      throw EvaluationFailure(description: "replay references unknown case \(episode.case_id)")
    }
    let outcome = try runCase(row, db: db, repo: repo, health: health,
      expectedEventCount: recordedEpisodes * 4)
    let context = "\(replayFile.version)/\(episode.case_id)"
    learner.recordOutcome(
      assessment: outcome.assessment, outcomeReward: episode.reward, contextKey: context)
    recordedEpisodes += 1
    let adjusted = outcome.assessment.signals.map { $0.adjustedScore }
    let blended = replayRewardBlend(reward: episode.reward, signals: outcome.produced.signals, adjusted: adjusted)
    let rows = try db.read { try Row.fetchAll($0, sql: "SELECT signal_key, alpha, beta FROM trust_vector_state") }
    var byKey = [String: (Double, Double)]()
    for dbRow in rows { byKey[dbRow["signal_key"] as String] = (dbRow["alpha"] as Double, dbRow["beta"] as Double) }
    for (index, signal) in outcome.produced.signals.enumerated() {
      let old = expected[signal.key] ?? priorFor(signal.key)
      let updateWeight = max(0.25, min(signal.weight, 1.6))
      let next = (1 + max(0, (old.alpha - 1) * 0.997) + blended[index] * updateWeight,
                  1 + max(0, (old.beta - 1) * 0.997) + (1 - blended[index]) * updateWeight)
      guard let saved = byKey[signal.key] else {
        throw EvaluationFailure(description: "missing trust row \(signal.key) at \(context)")
      }
      try require(abs(saved.0 - next.0) <= 1e-9 && abs(saved.1 - next.1) <= 1e-9,
        "replay trust mismatch \(context)/\(signal.key): stored=(\(saved.0), \(saved.1)) expected=(\(next.0), \(next.1))")
      expected[signal.key] = next
    }
  }
  let eventCount = (try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM confidence_signal_events") }) ?? -1
  try require(eventCount == replayFile.episodes.count * 4,
    "replay event count: expected \(replayFile.episodes.count * 4), got \(eventCount)")
  let trustCount = (try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM trust_vector_state") }) ?? -1
  try require(trustCount == 4, "replay trust row count: expected 4, got \(trustCount)")
  return eventCount
}

// MARK: - Entry

func seedCatalog() async throws -> (DatabaseQueue, Int, Int) {
  let db = try DatabaseQueue()
  try DatabaseMigrations.migrate(db)
  let appDB = AppDatabase(dbQueue: db)
  try await BundledDataLoader.loadInto(appDB)
  let recipeCount = (try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recipes") }) ?? 0
  let ingredientCount = (try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ingredients") }) ?? 0
  try require(recipeCount == 166 && ingredientCount == 50,
    "catalog seed mismatch: \(recipeCount) recipes, \(ingredientCount) ingredients")
  return (db, recipeCount, ingredientCount)
}

func run() async throws {
  let args = CommandLine.arguments
  guard args.count == 5, args[3] == "--result" else {
    throw EvaluationFailure(description: "usage: reverse-meal-scale-runner EVIDENCE_JSONL REPLAY_JSON --result RESULT_JSON")
  }
  let resultURL = URL(fileURLWithPath: args[4]).standardizedFileURL
  let recordURL = resultURL.deletingLastPathComponent().appendingPathComponent("execution-record.json")
  try require(resultURL != recordURL, "result must not be named execution-record.json")
  for url in [resultURL, recordURL] {
    try require(!FileManager.default.fileExists(atPath: url.path), "Refusing to overwrite existing output: \(url.path)")
  }

  let decoder = JSONDecoder()
  let evidenceRows = try String(contentsOfFile: args[1], encoding: .utf8)
    .split(separator: "\n").map { try decoder.decode(EvidenceRow.self, from: Data($0.utf8)) }
  let replayFile = try decoder.decode(ReplayFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
  try require(Set(evidenceRows.map(\.case_id)).count == evidenceRows.count, "duplicate case ids in evidence")
  try require(replayFile.version == "policy-study-dev-v2", "replay version mismatch")
  try require(replayFile.episodes.count == 200, "expected 200 dev episodes")
  var evidenceById = [String: EvidenceRow]()
  for row in evidenceRows { evidenceById[row.case_id] = row }

  // ---- Arms. Fresh DBs; the warm arm replays the dev episodes first. --------
  let (coldDB, recipeCount, ingredientCount) = try await seedCatalog()
  let (warmDB, _, _) = try await seedCatalog()
  let (coldRepo, coldHealth) = makeServices(db: coldDB)
  let (warmRepo, warmHealth) = makeServices(db: warmDB)
  _ = try replay(replayFile, evidence: evidenceById, db: warmDB, repo: warmRepo, health: warmHealth)

  var coldRows: [String: [String: Any]] = [:]
  var warmRows: [String: [String: Any]] = [:]
  for row in evidenceRows.sorted(by: { $0.case_id < $1.case_id }) {
    let cold = try runCase(row, db: coldDB, repo: coldRepo, health: coldHealth, expectedEventCount: 0)
    let warm = try runCase(row, db: warmDB, repo: warmRepo, health: warmHealth, expectedEventCount: 800)
    coldRows[row.case_id] = try outcomeJSON(cold)
    warmRows[row.case_id] = try outcomeJSON(warm)
  }

  // ---- Verification: rerun the sample on FRESH databases, in sorted order
  // (cold2) and reversed order (warm2 is freshly replayed too), then compare
  // canonical bytes against the main pass. Also reruns on the SAME databases
  // in reverse order to show assessment order-invariance.
  let sortedEvidence = evidenceRows.sorted { $0.case_id < $1.case_id }
  let sampleStride = max(1, sortedEvidence.count / 50)
  let sample = sortedEvidence.enumerated().filter { $0.offset % sampleStride == 0 }.map(\.element).prefix(50)
  let (cold2DB, _, _) = try await seedCatalog()
  let (warm2DB, _, _) = try await seedCatalog()
  let (cold2Repo, cold2Health) = makeServices(db: cold2DB)
  let (warm2Repo, warm2Health) = makeServices(db: warm2DB)
  _ = try replay(replayFile, evidence: evidenceById, db: warm2DB, repo: warm2Repo, health: warm2Health)
  for row in sample.reversed() {
    let cold2 = try runCase(row, db: cold2DB, repo: cold2Repo, health: cold2Health, expectedEventCount: 0)
    let warm2 = try runCase(row, db: warm2DB, repo: warm2Repo, health: warm2Health, expectedEventCount: 800)
    let coldMain = try runCase(row, db: coldDB, repo: coldRepo, health: coldHealth, expectedEventCount: 0)
    let warmMain = try runCase(row, db: warmDB, repo: warmRepo, health: warmHealth, expectedEventCount: 800)
    let cold2JSON = try canonicalJSON(outcomeJSON(cold2))
    let coldMainJSON = try canonicalJSON(outcomeJSON(coldMain))
    let warm2JSON = try canonicalJSON(outcomeJSON(warm2))
    let warmMainJSON = try canonicalJSON(outcomeJSON(warmMain))
    try require(cold2JSON == coldMainJSON, "cold fresh-DB mismatch: \(row.case_id)")
    try require(warm2JSON == warmMainJSON, "warm fresh-DB mismatch: \(row.case_id)")
  }

  // ---- Degenerate-input arm (spec v2 SS7 arm 3): producer must fail closed. --
  // Empty, single-item, duplicate, and unknown-ingredient requests built
  // deterministically from the first eval requests; outcomes recorded
  // verbatim, with fail-closed assertions (no events written on assess).
  var degenerateRows: [[String: Any]] = []
  func recordDegenerate(_ name: String, _ detections: [DetectionView], db: DatabaseQueue, repo: RecipeRepository, health: HealthScoringService) throws {
    let synthetic = EvidenceRow(case_id: name, detections: detections.map { [Double($0.ingredientId), $0.confidence] })
    let beforeEvents = (try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM confidence_signal_events") }) ?? -1
    let outcome = try runCase(synthetic, db: db, repo: repo, health: health, expectedEventCount: beforeEvents)
    try require(!outcome.produced.hardFailReasons.isEmpty || !outcome.candidates.isEmpty,
      "degenerate case \(name) produced neither hard-fail nor candidates")
    if detections.isEmpty {
      try require(outcome.candidates.isEmpty && !outcome.produced.hardFailReasons.isEmpty,
        "empty evidence must fail closed: \(name)")
    }
    let json = try outcomeJSON(outcome)
    degenerateRows.append([
      "case_id": name,
      "detections": detections.map { [Double($0.ingredientId), $0.confidence] },
      "outcome": json,
    ])
  }
  for row in sortedEvidence.prefix(5) {
    let dets = row.detections.map { DetectionView(ingredientId: Int64($0[0]), confidence: Double(Float($0[1]))) }
    if let top = dets.max(by: { $0.confidence < $1.confidence }) {
      try recordDegenerate("degenerate-single-\(row.case_id)", [top], db: coldDB, repo: coldRepo, health: coldHealth)
    }
    if !dets.isEmpty {
      try recordDegenerate("degenerate-duplicate-\(row.case_id)", dets + dets, db: coldDB, repo: coldRepo, health: coldHealth)
    }
  }
  try recordDegenerate("degenerate-empty", [], db: coldDB, repo: coldRepo, health: coldHealth)
  try recordDegenerate(
    "degenerate-unknown-ingredients",
    [DetectionView(ingredientId: 999999, confidence: 0.7), DetectionView(ingredientId: 999998, confidence: 0.55)],
    db: coldDB, repo: coldRepo, health: coldHealth)

  let record: [String: Any] = [
    "recipe_count": recipeCount,
    "ingredient_count": ingredientCount,
    "case_count": evidenceRows.count,
    "replay_episodes": replayFile.episodes.count,
    "verification_sample_size": sample.count,
    "degenerate_cases": degenerateRows.count,
  ]
  let output: [String: Any] = [
    "version": "policy-study-v2",
    "arms": [
      "learner-cold": Array(coldRows.values),
      "learner-devwarm": Array(warmRows.values),
      "degenerate-input": degenerateRows,
    ],
    "execution_record": record,
  ]
  try (try canonicalJSON(output) as Data).write(to: resultURL)
  let recordData = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
  try recordData.write(to: recordURL)
}

do {
  try await run()
} catch {
  if let failure = error as? EvaluationFailure {
    FileHandle.standardError.write(Data("evaluation failure: \(failure.description)\n".utf8))
  } else {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  }
  exit(1)
}
