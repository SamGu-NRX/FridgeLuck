import Foundation

/// Routes scan detections into UX categories based on confidence.
/// High confidence → auto-add
/// Medium confidence → ask user to confirm
/// Low confidence → show in "possible" tray
enum ConfidenceRouter {
  enum Thresholds {
    static let visionAuto: Float = 0.82
    static let visionConfirmMin: Float = 0.45

    static let ocrExactAuto: Float = 0.90
    static let ocrExactConfirmMin: Float = 0.60

    static let ocrFuzzyConfirmMin: Float = 0.55
  }

  struct CategorizedResults: Sendable {
    let confirmed: [Detection]
    let needsConfirmation: [Detection]
    let possible: [Detection]
  }

  static func bucket(for detection: Detection) -> ConfidenceBucket {
    switch detection.source {
    case .manual:
      return .auto

    case .vision:
      if detection.confidence >= Thresholds.visionAuto { return .auto }
      if detection.confidence >= Thresholds.visionConfirmMin { return .confirm }
      return .possible

    case .ocr:
      switch detection.ocrMatchKind ?? .exact {
      case .exact:
        if detection.confidence >= Thresholds.ocrExactAuto { return .auto }
        if detection.confidence >= Thresholds.ocrExactConfirmMin { return .confirm }
        return .possible
      case .fuzzy:
        if detection.confidence >= Thresholds.ocrFuzzyConfirmMin { return .confirm }
        return .possible
      }
    }
  }

  static func categorize(_ detections: [Detection]) -> CategorizedResults {
    var confirmed: [Detection] = []
    var needsConfirmation: [Detection] = []
    var possible: [Detection] = []

    for detection in detections {
      switch bucket(for: detection) {
      case .auto:
        confirmed.append(detection)
      case .confirm:
        needsConfirmation.append(detection)
      case .possible:
        possible.append(detection)
      }
    }

    return CategorizedResults(
      confirmed: confirmed,
      needsConfirmation: needsConfirmation,
      possible: possible
    )
  }

  /// Confidence is a source-aware routing score for UX buckets.
  /// It is not a calibrated probability of correctness.
  static func explanation(for detection: Detection) -> String {
    let score = Int((detection.confidence * 100).rounded())
    switch detection.source {
    case .manual:
      return "Manual confirmation (trusted user input)."
    case .vision:
      return
        "Vision score \(score)% from whole-image classification; used for routing only (not a guarantee)."
    case .ocr:
      switch detection.ocrMatchKind ?? .exact {
      case .exact:
        return
          "OCR exact token match, routed with high trust at \(score)% score (still reviewable)."
      case .fuzzy:
        return
          "OCR fuzzy token match at \(score)% score; confirmation recommended before auto-use."
      }
    }
  }

  static func label(for bucket: ConfidenceBucket) -> String {
    switch bucket {
    case .auto: return "Auto"
    case .confirm: return "Confirm"
    case .possible: return "Possible"
    }
  }
}
