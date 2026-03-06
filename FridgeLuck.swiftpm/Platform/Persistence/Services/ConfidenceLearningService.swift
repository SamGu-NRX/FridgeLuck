import Foundation
import GRDB
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "ConfidenceLearning")

enum ConfidenceAssessmentMode: String, Sendable, Codable {
  case exact
  case reviewRequired = "review_required"
  case estimateOnly = "estimate_only"

  var statusText: String {
    switch self {
    case .exact: return "Exact"
    case .reviewRequired: return "Needs Review"
    case .estimateOnly: return "Estimate"
    }
  }
}

struct ConfidenceSignalInput: Sendable {
  let key: String
  let rawScore: Double
  let weight: Double
  let reason: String

  init(key: String, rawScore: Double, weight: Double = 1.0, reason: String) {
    self.key = key
    self.rawScore = max(0, min(rawScore, 1.0))
    self.weight = max(0.05, weight)
    self.reason = reason
  }
}

struct ConfidenceSignalAssessment: Sendable {
  let key: String
  let rawScore: Double
  let adjustedScore: Double
  let trustMean: Double
  let trustUncertainty: Double
  let weight: Double
  let reason: String
}

struct ConfidenceAssessment: Sendable {
  let mode: ConfidenceAssessmentMode
  let overallScore: Double
  let deterministicReady: Bool
  let reasons: [String]
  let signals: [ConfidenceSignalAssessment]
}

struct ConfidenceCalibrationSnapshot: Sendable {
  let signalKey: String
  let eventCount: Int
  let averageRawScore: Double
  let averageOutcomeReward: Double
  let averageAbsoluteError: Double
  let trustMean: Double
  let trustUncertainty: Double
}

/// Lightweight Bayesian trust-vector learner.
/// Uses online rewards from user actions so confidence can improve without a large labeled dataset.
final class ConfidenceLearningService: @unchecked Sendable {
  private struct TrustState {
    let alpha: Double
    let beta: Double

    var mean: Double {
      alpha / (alpha + beta)
    }

    var uncertainty: Double {
      sqrt((mean * (1 - mean)) / (alpha + beta + 1))
    }

    var sampleSize: Double {
      alpha + beta
    }
  }

  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  func assess(
    signals: [ConfidenceSignalInput],
    hardFailReasons: [String] = []
  ) -> ConfidenceAssessment {
    logger.debug(
      "Assessing confidence. signals=\(signals.count, privacy: .public), hardFails=\(hardFailReasons.count, privacy: .public)"
    )
    guard !signals.isEmpty else {
      return ConfidenceAssessment(
        mode: .estimateOnly,
        overallScore: 0,
        deterministicReady: false,
        reasons: ["No confidence signals available."],
        signals: []
      )
    }

    let assessedSignals =
      (try? db.read { db in
        try signals.map { signal in
          let trust = try loadTrust(for: signal.key, db: db) ?? prior(for: signal.key)
          return assessSignal(signal, trust: trust)
        }
      })
      ?? signals.map { signal in
        assessSignal(signal, trust: prior(for: signal.key))
      }

    let totalWeight = assessedSignals.reduce(0.0) { $0 + $1.weight }
    let weightedLogSum = assessedSignals.reduce(0.0) { partial, signal in
      partial + (signal.weight * log(max(signal.adjustedScore, 0.0001)))
    }

    var overall = exp(weightedLogSum / max(totalWeight, 0.0001))

    let lowSignals = assessedSignals.filter { $0.adjustedScore < 0.45 }
    let contradictionPenalty = Double(lowSignals.count) * 0.08
    overall = max(0, min(overall - contradictionPenalty, 1.0))

    var reasons = hardFailReasons
    for signal in lowSignals.prefix(3) {
      reasons.append("Low confidence in \(signal.reason.lowercased()).")
    }

    let mode: ConfidenceAssessmentMode
    if !hardFailReasons.isEmpty {
      mode = .estimateOnly
      overall = min(overall, 0.42)
    } else {
      let minimumAdjusted = assessedSignals.map(\.adjustedScore).min() ?? 0
      if overall >= 0.84 && minimumAdjusted >= 0.62 {
        mode = .exact
      } else if overall >= 0.57 {
        mode = .reviewRequired
      } else {
        mode = .estimateOnly
      }
    }

    if reasons.isEmpty {
      reasons.append("Confidence mode: \(mode.statusText).")
    }

    logger.info(
      "Confidence assessed. mode=\(mode.rawValue, privacy: .public), overall=\(overall, privacy: .public), deterministicReady=\(mode == .exact, privacy: .public)"
    )
    for signal in assessedSignals {
      logger.debug(
        "signal=\(signal.key, privacy: .public), raw=\(signal.rawScore, privacy: .public), adjusted=\(signal.adjustedScore, privacy: .public), trustMean=\(signal.trustMean, privacy: .public), trustUncertainty=\(signal.trustUncertainty, privacy: .public)"
      )
    }

    return ConfidenceAssessment(
      mode: mode,
      overallScore: max(0, min(overall, 1.0)),
      deterministicReady: mode == .exact,
      reasons: reasons,
      signals: assessedSignals
    )
  }

  func recordOutcome(
    assessment: ConfidenceAssessment,
    outcomeReward: Double,
    contextKey: String? = nil,
    note: String? = nil
  ) {
    guard !assessment.signals.isEmpty else { return }
    let reward = max(0, min(outcomeReward, 1.0))
    logger.info(
      "Recording confidence outcome. mode=\(assessment.mode.rawValue, privacy: .public), reward=\(reward, privacy: .public), context=\(contextKey ?? "-", privacy: .public), signals=\(assessment.signals.count, privacy: .public)"
    )

    try? db.write { db in
      for signal in assessment.signals {
        let calibrationReward = max(0, min(1 - abs(reward - signal.adjustedScore), 1.0))
        let blendedSignalReward = max(
          0,
          min((reward * 0.55) + (calibrationReward * 0.45), 1.0)
        )
        let updateWeight = max(0.25, min(signal.weight, 1.6))
        let mergedNote = mergeNote(
          base: note,
          mode: assessment.mode,
          adjustedScore: signal.adjustedScore,
          signalReward: blendedSignalReward
        )

        try db.execute(
          sql: """
            INSERT INTO confidence_signal_events
                (signal_key, context_key, raw_score, outcome_reward, note, created_at)
            VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            """,
          arguments: [signal.key, contextKey, signal.rawScore, blendedSignalReward, mergedNote]
        )

        let existing = try loadTrust(for: signal.key, db: db) ?? prior(for: signal.key)
        let decay = 0.997
        let nextAlpha =
          1 + max(0, (existing.alpha - 1) * decay) + (blendedSignalReward * updateWeight)
        let nextBeta =
          1 + max(0, (existing.beta - 1) * decay) + ((1 - blendedSignalReward) * updateWeight)

        try db.execute(
          sql: """
            INSERT INTO trust_vector_state
                (signal_key, alpha, beta, updated_at)
            VALUES (?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(signal_key)
            DO UPDATE SET
                alpha = excluded.alpha,
                beta = excluded.beta,
                updated_at = excluded.updated_at
            """,
          arguments: [signal.key, nextAlpha, nextBeta]
        )

        logger.debug(
          "Updated trust vector. signal=\(signal.key, privacy: .public), alpha=\(nextAlpha, privacy: .public), beta=\(nextBeta, privacy: .public), weightedReward=\(blendedSignalReward, privacy: .public)"
        )
      }
    }
  }

  func calibrationSnapshots(limit: Int = 40) -> [ConfidenceCalibrationSnapshot] {
    let safeLimit = max(1, min(limit, 200))
    let snapshots =
      (try? db.read { db -> [ConfidenceCalibrationSnapshot] in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT
              signal_key,
              COUNT(*) AS event_count,
              AVG(raw_score) AS avg_raw_score,
              AVG(outcome_reward) AS avg_outcome_reward,
              AVG(ABS(raw_score - outcome_reward)) AS avg_abs_error
            FROM confidence_signal_events
            GROUP BY signal_key
            ORDER BY event_count DESC
            LIMIT ?
            """,
          arguments: [safeLimit]
        )

        return try rows.map { row in
          let key: String = row["signal_key"]
          let trust = try loadTrust(for: key, db: db) ?? prior(for: key)
          return ConfidenceCalibrationSnapshot(
            signalKey: key,
            eventCount: row["event_count"] as Int,
            averageRawScore: row["avg_raw_score"] as Double? ?? 0,
            averageOutcomeReward: row["avg_outcome_reward"] as Double? ?? 0,
            averageAbsoluteError: row["avg_abs_error"] as Double? ?? 0,
            trustMean: trust.mean,
            trustUncertainty: trust.uncertainty
          )
        }
      }) ?? []

    logger.debug(
      "Loaded confidence calibration snapshots. count=\(snapshots.count, privacy: .public)"
    )
    return snapshots
  }

  private func assessSignal(_ signal: ConfidenceSignalInput, trust: TrustState)
    -> ConfidenceSignalAssessment
  {
    let trustInfluence = max(0.20, min((trust.sampleSize - 2.0) / 18.0, 1.0))
    let trustWeightedRaw = signal.rawScore * trust.mean
    let blended = (signal.rawScore * (1 - trustInfluence)) + (trustWeightedRaw * trustInfluence)
    let uncertaintyPenalty = 0.20 * trust.uncertainty
    let adjusted = max(0, min(blended - uncertaintyPenalty, 1.0))

    return ConfidenceSignalAssessment(
      key: signal.key,
      rawScore: signal.rawScore,
      adjustedScore: adjusted,
      trustMean: trust.mean,
      trustUncertainty: trust.uncertainty,
      weight: signal.weight,
      reason: signal.reason
    )
  }

  private func loadTrust(for key: String, db: Database) throws -> TrustState? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT alpha, beta FROM trust_vector_state WHERE signal_key = ? LIMIT 1",
        arguments: [key]
      )
    else {
      return nil
    }

    let alpha = max(1.0, row["alpha"] as Double)
    let beta = max(1.0, row["beta"] as Double)
    return TrustState(alpha: alpha, beta: beta)
  }

  private func prior(for key: String) -> TrustState {
    let normalized = key.lowercased()

    if normalized.contains("ocr_exact") {
      return TrustState(alpha: 7.0, beta: 2.0)
    }
    if normalized.contains("vision") {
      return TrustState(alpha: 6.0, beta: 2.4)
    }
    if normalized.contains("ocr_fuzzy") {
      return TrustState(alpha: 3.4, beta: 3.0)
    }
    if normalized.contains("portion") {
      return TrustState(alpha: 2.8, beta: 3.6)
    }
    if normalized.contains("macro") {
      return TrustState(alpha: 4.4, beta: 2.8)
    }
    if normalized.contains("gemini") {
      return TrustState(alpha: 4.8, beta: 2.7)
    }
    if normalized.contains("recipe") {
      return TrustState(alpha: 4.5, beta: 2.9)
    }

    return TrustState(alpha: 4.0, beta: 3.0)
  }

  private func mergeNote(
    base: String?,
    mode: ConfidenceAssessmentMode,
    adjustedScore: Double,
    signalReward: Double
  ) -> String {
    let components = [
      base,
      "mode=\(mode.rawValue)",
      "adjusted=\(formatted(adjustedScore))",
      "signal_reward=\(formatted(signalReward))",
    ]
    .compactMap { $0 }
    return components.joined(separator: " | ")
  }

  private func formatted(_ value: Double) -> String {
    String(format: "%.4f", value)
  }
}
