import Foundation

/// One projected reverse-meal confidence signal, in the exact shape the confidence learner
/// consumes. The learner's own `ConfidenceSignalInput` clamps at construction; this type
/// carries the computed values as the shipped calculation produces them.
public struct ReverseScanSignal: Sendable, Equatable {
  public let key: String
  public let rawScore: Double
  public let weight: Double
  public let reason: String

  public init(key: String, rawScore: Double, weight: Double, reason: String) {
    self.key = key
    self.rawScore = rawScore
    self.weight = weight
    self.reason = reason
  }
}

/// The facts the reverse-meal signals and hard-failure rules read from a ranked recipe
/// candidate: its confidence score and required-ingredient bookkeeping. Candidates must be
/// supplied in ranked order; the calculation never re-sorts.
public struct ReverseScanCandidateFacts: Sendable, Equatable {
  public let confidenceScore: Double
  public let matchedRequired: Int
  public let totalRequired: Int
  public let missingRequiredCount: Int

  public init(
    confidenceScore: Double,
    matchedRequired: Int,
    totalRequired: Int,
    missingRequiredCount: Int
  ) {
    self.confidenceScore = confidenceScore
    self.matchedRequired = matchedRequired
    self.totalRequired = totalRequired
    self.missingRequiredCount = missingRequiredCount
  }
}

/// The shipped reverse-meal signal and hard-failure calculation, extracted verbatim from
/// `ReverseScanService` so the product and the reverse-meal-v1 evaluation share one
/// implementation.
///
/// Behavior is pinned by the committed reverse-meal evaluation fixtures
/// (`backend/gemini-agent/evaluation-fixtures/reverse-meal-states-v1.jsonl` against the
/// matching `projected-requests.jsonl`): detection confidences convert from Float32 before
/// the Double accumulation, candidates are consumed in the order supplied, a single
/// candidate scores a fixed 0.82 candidate-margin raw score while two or more clamp
/// `0.5 + gap` into `[0, 1]`, and hard failures follow strict first-failure precedence with
/// a strict binary64 `gap < 0.06` ambiguity rule — no epsilon, no decimal rounding.
public enum ReverseScanFeatureLogic {
  /// Mean detection confidence. Each Float32 confidence widens to Double before the clamp
  /// and the accumulation, so the mean matches the Vision pipeline bit for bit.
  public static func meanDetectionConfidence(_ confidences: [Float]) -> Double {
    guard !confidences.isEmpty else { return 0 }
    let sum = confidences.reduce(0.0) { partial, confidence in
      partial + max(0, min(Double(confidence), 1.0))
    }
    return sum / Double(confidences.count)
  }

  /// The four shipped reverse-meal signals, in the learner's fixed key order.
  public static func confidenceSignals(
    overallDetectionConfidence: Double,
    candidates: [ReverseScanCandidateFacts]
  ) -> [ReverseScanSignal] {
    let topCandidate = candidates.first
    let topScore = topCandidate?.confidenceScore ?? 0

    let requiredCoverage: Double
    if let top = topCandidate {
      requiredCoverage = Double(top.matchedRequired) / Double(max(top.totalRequired, 1))
    } else {
      requiredCoverage = 0
    }

    let marginScore: Double
    if candidates.count >= 2 {
      let margin = max(0, (candidates[0].confidenceScore - candidates[1].confidenceScore))
      marginScore = max(0, min(0.5 + margin, 1.0))
    } else if candidates.count == 1 {
      marginScore = 0.82
    } else {
      marginScore = 0
    }

    return [
      ReverseScanSignal(
        key: "reverse_scan.vision_detection",
        rawScore: overallDetectionConfidence,
        weight: 0.32,
        reason: "ingredient detection"
      ),
      ReverseScanSignal(
        key: "reverse_scan.recipe_match",
        rawScore: topScore,
        weight: 0.30,
        reason: "recipe match"
      ),
      ReverseScanSignal(
        key: "reverse_scan.required_coverage",
        rawScore: requiredCoverage,
        weight: 0.23,
        reason: "required ingredient coverage"
      ),
      ReverseScanSignal(
        key: "reverse_scan.candidate_margin",
        rawScore: marginScore,
        weight: 0.15,
        reason: "candidate ambiguity"
      ),
    ]
  }

  /// Hard failures in shipped first-failure precedence: no candidate, then missing required
  /// ingredients, then candidate ambiguity.
  public static func hardFailReasons(candidates: [ReverseScanCandidateFacts]) -> [String] {
    guard let top = candidates.first else {
      return ["No confident recipe candidate."]
    }

    if top.missingRequiredCount > 2 {
      return ["Too many required ingredients are missing."]
    }

    if candidates.count >= 2 {
      let gap = top.confidenceScore - candidates[1].confidenceScore
      if gap < 0.06 {
        return ["Top recipe candidates are highly ambiguous."]
      }
    }

    return []
  }
}
