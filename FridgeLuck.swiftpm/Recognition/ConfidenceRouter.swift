import Foundation

/// Routes scan detections into UX categories based on confidence.
/// High confidence → auto-add
/// Medium confidence → ask user to confirm
/// Low confidence → show in "possible" tray
enum ConfidenceRouter {
  struct CategorizedResults: Sendable {
    let confirmed: [Detection]  // >= 0.65 confidence
    let needsConfirmation: [Detection]  // 0.35 ..< 0.65
    let possible: [Detection]  // < 0.35
  }

  static func categorize(_ detections: [Detection]) -> CategorizedResults {
    var confirmed: [Detection] = []
    var needsConfirmation: [Detection] = []
    var possible: [Detection] = []

    for detection in detections {
      switch detection.confidence {
      case 0.65...:
        confirmed.append(detection)
      case 0.35..<0.65:
        needsConfirmation.append(detection)
      default:
        possible.append(detection)
      }
    }

    return CategorizedResults(
      confirmed: confirmed,
      needsConfirmation: needsConfirmation,
      possible: possible
    )
  }
}
