import Foundation
import CryptoKit
import GRDB

struct EvaluationFailure: Error, CustomStringConvertible {
  let description: String
}
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw EvaluationFailure(description: message) }
}
func near(_ actual: Double, _ expected: Double, _ message: String) throws {
  try require(actual.isFinite && expected.isFinite && abs(actual - expected) <= 1e-12,
    "\(message): actual=\(actual), expected=\(expected)")
}
struct Candidate: Decodable {
  let id: Int
  let confidence_score: Double
  let matched_required: Int
  let total_required: Int
  let missing_required_count: Int
}
struct ProducerState: Decodable {
  let detection_confidences: [Double]
  let ranked_candidates: [Candidate]
}
struct StateRow: Decodable {
  let case_id: String
  let producer_state: ProducerState
}
struct Episode: Decodable {
  let episode_id: String
  let state_id: String
  let proxy_reward: Double
  let truth_reward: Double
}
struct Replay: Decodable {
  let version: String
  let states: [String: ProducerState]
  let episodes: [Episode]
}
let keys = ["reverse_scan.vision_detection", "reverse_scan.recipe_match", "reverse_scan.required_coverage", "reverse_scan.candidate_margin"]
let weights = [0.32, 0.30, 0.23, 0.15]
let reasons = ["ingredient detection", "recipe match", "required ingredient coverage", "candidate ambiguity"]
struct Request {
  let signals: [ConfidenceSignalInput]
  let hardFailReasons: [String]
  var json: [String: Any] {
    ["signals": signals.map { ["key": $0.key, "rawScore": $0.rawScore, "weight": $0.weight, "reason": $0.reason] as [String: Any] }, "hardFailReasons": hardFailReasons]
  }
}
func project(_ state: ProducerState) -> Request {
  let cs = state.ranked_candidates
  let top = cs.first
  let mean = state.detection_confidences.isEmpty ? 0 : state.detection_confidences.reduce(0.0) {
    $0 + max(0, min(Double(Float($1)), 1))
  } / Double(state.detection_confidences.count)
  let coverage = top.map { Double($0.matched_required) / Double(max($0.total_required, 1)) } ?? 0
  let gap: Double? = cs.count >= 2 ? cs[0].confidence_score - cs[1].confidence_score : nil
  let margin = gap.map { max(0, min(0.5 + max($0, 0), 1)) } ?? (top == nil ? 0 : 0.82)
  let values = [mean, top?.confidence_score ?? 0, coverage, margin]
  let fails: [String]
  if top == nil { fails = ["No confident recipe candidate."] }
  else if top!.missing_required_count > 2 { fails = ["Too many required ingredients are missing."] }
  else if let gap, gap < 0.06 { fails = ["Top recipe candidates are highly ambiguous."] }
  else { fails = [] }
  return Request(signals: keys.indices.map { ConfidenceSignalInput(key: keys[$0], rawScore: values[$0], weight: weights[$0], reason: reasons[$0]) }, hardFailReasons: fails)
}
func jsonData(_ value: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}
func assessmentJSON(_ assessment: ConfidenceAssessment) -> [String: Any] {
  ["mode": assessment.mode.rawValue, "overallScore": assessment.overallScore,
   "deterministicReady": assessment.deterministicReady, "reasons": assessment.reasons,
   "signals": assessment.signals.map {
     ["key": $0.key, "rawScore": $0.rawScore, "adjustedScore": $0.adjustedScore,
      "trustMean": $0.trustMean, "trustUncertainty": $0.trustUncertainty,
      "weight": $0.weight, "reason": $0.reason] as [String: Any]
   }]
}
struct Trust {
  let alpha: Double
  let beta: Double
}
func prior(_ key: String) -> Trust {
  if key == keys[0] { return Trust(alpha: 6, beta: 2.4) }
  if key == keys[1] { return Trust(alpha: 4.5, beta: 2.9) }
  return Trust(alpha: 4, beta: 3)
}
func trustRows(_ db: DatabaseQueue) throws -> [[String: Any]] {
  try db.read { db in
    try Row.fetchAll(db, sql: "SELECT signal_key, alpha, beta FROM trust_vector_state ORDER BY signal_key").map { row in
      let key: String = row["signal_key"], alpha: Double = row["alpha"], beta: Double = row["beta"]
      try require(keys.contains(key) && alpha.isFinite && beta.isFinite && alpha >= 1 && beta >= 1, "invalid direct trust row: \(key)")
      return ["signal_key": key, "alpha": alpha, "beta": beta]
    }
  }
}
func eventRows(_ db: DatabaseQueue) throws -> [[String: Any]] {
  try db.read { db in
    try Row.fetchAll(db, sql: "SELECT id, signal_key, context_key, raw_score, outcome_reward, note FROM confidence_signal_events ORDER BY id").map { row in
      ["id": row["id"] as Int, "signal_key": row["signal_key"] as String,
       "context_key": row["context_key"] as String, "raw_score": row["raw_score"] as Double,
       "outcome_reward": row["outcome_reward"] as Double, "note": row["note"] as String]
    }
  }
}
func assertCounts(_ db: DatabaseQueue, episodes: Int) throws {
  try db.read { db in
    let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM confidence_signal_events")
    let trust = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trust_vector_state")
    try require(events == episodes * 4, "event row count: expected \(episodes * 4), got \(String(describing: events))")
    try require(trust == (episodes == 0 ? 0 : 4), "trust row count: expected \(episodes == 0 ? 0 : 4), got \(String(describing: trust))")
    let grouped = try Row.fetchAll(db, sql: "SELECT signal_key, COUNT(*) AS n FROM confidence_signal_events GROUP BY signal_key ORDER BY signal_key")
    try require(grouped.count == (episodes == 0 ? 0 : 4), "unexpected event keys")
    for row in grouped {
      let key: String = row["signal_key"], count: Int = row["n"]
      try require(keys.contains(key) && count == episodes, "event per-key count: \(key), \(count)")
    }
  }
}
func assess(_ service: ConfidenceLearningService, _ request: Request) -> ConfidenceAssessment {
  service.assess(signals: request.signals, hardFailReasons: request.hardFailReasons)
}
func runCase(_ row: StateRow, arm: String, replay: Replay) throws -> [String: Any] {
  let db = try DatabaseQueue()
  try DatabaseMigrations.migrate(db)
  try assertCounts(db, episodes: 0)
  let service = ConfidenceLearningService(db: db)
  var expected = Dictionary(uniqueKeysWithValues: keys.map { ($0, prior($0)) })
  var rewardAssertions = 0
  if arm != "ios-A0" {
    for (index, episode) in replay.episodes.enumerated() {
      guard let state = replay.states[episode.state_id] else { throw EvaluationFailure(description: "missing replay state \(episode.state_id)") }
      let assessment = assess(service, project(state))
      let reward = arm == "ios-A1-proxy" ? episode.proxy_reward : episode.truth_reward
      let context = "\(replay.version)/\(episode.episode_id)"
      service.recordOutcome(assessment: assessment, outcomeReward: reward, contextKey: context)
      // recordOutcome uses try?. These SQL assertions must reject a suppressed write failure.
      try assertCounts(db, episodes: index + 1)
      let events = try eventRows(db).suffix(4)
      for (event, signal) in zip(events, assessment.signals) {
        let calibration = max(0, min(1 - abs(reward - signal.adjustedScore), 1))
        let blended = max(0, min(reward * 0.55 + calibration * 0.45, 1))
        try require(event["signal_key"] as? String == signal.key && event["context_key"] as? String == context, "event key/context mismatch")
        try near(event["raw_score"] as! Double, signal.rawScore, "stored raw score \(context)/\(signal.key)")
        try near(event["outcome_reward"] as! Double, blended, "stored blended reward \(context)/\(signal.key)")
        let old = expected[signal.key]!
        let updateWeight = max(0.25, min(signal.weight, 1.6))
        expected[signal.key] = Trust(alpha: 1 + max(0, (old.alpha - 1) * 0.997) + blended * updateWeight,
          beta: 1 + max(0, (old.beta - 1) * 0.997) + (1 - blended) * updateWeight)
        rewardAssertions += 1
      }
      for saved in try trustRows(db) {
        let key = saved["signal_key"] as! String
        try near(saved["alpha"] as! Double, expected[key]!.alpha, "stored alpha \(context)/\(key)")
        try near(saved["beta"] as! Double, expected[key]!.beta, "stored beta \(context)/\(key)")
      }
    }
    try require(rewardAssertions == 48, "expected 48 blended reward assertions")
  }
  let request = project(row.producer_state)
  let result = assess(service, request)
  let reopened = assess(ConfidenceLearningService(db: db), request)
  try require(try jsonData(assessmentJSON(result)) == jsonData(assessmentJSON(reopened)), "second learner persistence mismatch: \(row.case_id)/\(arm)")
  let trust = try trustRows(db)
  if arm != "ios-A0" {
    for signal in reopened.signals {
      let saved = expected[signal.key]!
      let initial = prior(signal.key)
      try require(saved.alpha != initial.alpha || saved.beta != initial.beta, "trust remained at prior: \(signal.key)")
      let mean = saved.alpha / (saved.alpha + saved.beta)
      try near(signal.trustMean, mean, "new instance trust mean: \(signal.key)")
      try near(signal.trustUncertainty, sqrt(mean * (1 - mean) / (saved.alpha + saved.beta + 1)), "new instance uncertainty: \(signal.key)")
    }
  }
  return ["case_id": row.case_id, "assessment": assessmentJSON(result), "trust_state": trust,
    "events": try eventRows(db), "db_assertions": ["before_event_rows": 0, "before_trust_rows": 0,
      "after_event_rows": arm == "ios-A0" ? 0 : 48, "after_trust_rows": trust.count,
      "events_per_key": arm == "ios-A0" ? 0 : 12, "blended_reward_assertions": rewardAssertions,
      "second_instance_persistence": true]]
}
func shuffled(_ rows: [StateRow]) -> [StateRow] {
  var result = rows
  var seed: UInt64 = 0x7265766572736531
  for index in stride(from: result.count - 1, through: 1, by: -1) {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    result.swapAt(index, Int(seed % UInt64(index + 1)))
  }
  return result
}
func assertSuppressedFailureDetected(_ state: ProducerState) throws {
  let db = try DatabaseQueue()
  try DatabaseMigrations.migrate(db)
  try db.write { db in
    try db.execute(sql: "CREATE TRIGGER reject_eval_event BEFORE INSERT ON confidence_signal_events BEGIN SELECT RAISE(ABORT, 'evaluation injected write failure'); END")
  }
  let service = ConfidenceLearningService(db: db)
  service.recordOutcome(assessment: assess(service, project(state)), outcomeReward: 0.96, contextKey: "write-failure-test")
  var detected = false
  do { try assertCounts(db, episodes: 1) }
  catch let error as EvaluationFailure { detected = error.description.contains("event row count") }
  try require(detected, "SQL assertions failed to catch suppressed write error")
}
func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func run() throws {
  let startedAt = Date()
  try require(CommandLine.arguments.count == 5 && CommandLine.arguments[3] == "--result",
    "usage: reverse-meal-runner STATES_JSONL REPLAY_JSON --result RESULT_JSON")
  let resultURL = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL
  let recordURL = resultURL.deletingLastPathComponent().appendingPathComponent("execution-record.json")
  try require(resultURL != recordURL, "result must not be named execution-record.json")
  for url in [resultURL, recordURL] {
    try require(!FileManager.default.fileExists(atPath: url.path), "Refusing to overwrite existing output: \(url.path)")
  }
  let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
  let executableHash = sha256(try Data(contentsOf: executableURL))
  let decoder = JSONDecoder()
  let statesText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
  let rows = try statesText.split(separator: "\n").map { try decoder.decode(StateRow.self, from: Data($0.utf8)) }
  let replay = try decoder.decode(Replay.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
  try require(rows.count == 16 && Set(rows.map(\.case_id)).count == 16 && replay.version == "reverse-meal-dev-v1" && replay.episodes.count == 12, "fixture cardinality/version mismatch")
  try assertSuppressedFailureDetected(rows[2].producer_state)
  var arms: [[String: Any]] = []
  for arm in ["ios-A0", "ios-A1-proxy", "ios-A1-truth-control"] {
    var baseline: [String: Data] = [:]
    let results = try rows.map { row -> [String: Any] in
      let result = try runCase(row, arm: arm, replay: replay)
      baseline[row.case_id] = try jsonData(result)
      return result
    }
    // Episode order is never changed. Each evaluation attempt gets a fresh migrated DB.
    for order in [rows, Array(rows.reversed()), shuffled(rows)] {
      for row in order {
        try require(try jsonData(runCase(row, arm: arm, replay: replay)) == baseline[row.case_id], "fresh DB reproducibility/order mismatch: \(arm)/\(row.case_id)")
      }
    }
    arms.append(["candidate": arm, "results": results.sorted { ($0["case_id"] as! String) < ($1["case_id"] as! String) }])
  }
  let projections = try rows.map { row in
    let request = project(row.producer_state).json
    return ["case_id": row.case_id, "request": request, "serialized_request": String(decoding: try jsonData(request), as: UTF8.self)] as [String: Any]
  }
  let replayProjections = try replay.states.keys.sorted().map { id in
    let request = project(replay.states[id]!).json
    return ["state_id": id, "request": request, "serialized_request": String(decoding: try jsonData(request), as: UTF8.self)] as [String: Any]
  }
  let document: [String: Any] = ["serializer": "Foundation.JSONSerialization sortedKeys withoutEscapingSlashes",
    "candidates": arms, "projections": projections, "replay_projections": replayProjections,
    "checks": ["case_runs": 192, "warm_case_runs": 128, "warm_blended_reward_assertions": 6144,
      "fresh_repeat_forward_reverse_seeded_shuffle": true, "shuffle_seed_hex": "7265766572736531",
      "suppressed_write_failure_detected": true, "timestamps_excluded_from_reproducibility": true]]
  var resultBytes = try jsonData(document)
  resultBytes.append(10)
  try resultBytes.write(to: resultURL, options: .withoutOverwriting)
  let formatter = ISO8601DateFormatter()
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let record: [String: Any] = [
    "schema": "reverse-meal-execution-record-v1", "executable_sha256": executableHash,
    "started_at": formatter.string(from: startedAt), "finished_at": formatter.string(from: Date()),
    "result_sha256": sha256(resultBytes), "argv": CommandLine.arguments
  ]
  var recordBytes = try jsonData(record)
  recordBytes.append(10)
  try recordBytes.write(to: recordURL, options: .withoutOverwriting)
}
do { try run() }
catch {
  FileHandle.standardError.write(Data("reverse-meal evaluation failed: \(error)\n".utf8))
  exit(1)
}
