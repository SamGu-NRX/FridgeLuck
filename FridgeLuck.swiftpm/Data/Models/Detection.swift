import Foundation

// MARK: - Detection Source

enum DetectionSource: String, Sendable {
  case vision
  case ocr
  case manual
}

// MARK: - Detection

struct Detection: Identifiable, Sendable {
  let id = UUID()
  let ingredientId: Int64
  let label: String
  let confidence: Float
  let source: DetectionSource
  let originalVisionLabel: String

  var isHighConfidence: Bool { confidence >= 0.65 }
  var isMediumConfidence: Bool { confidence >= 0.35 && confidence < 0.65 }
  var isLowConfidence: Bool { confidence < 0.35 }
}

// MARK: - Detection Category

enum DetectionCategory: Sendable {
  case autoConfirm
  case askUser(alternatives: [String])
  case possibleItem

  static func categorize(_ detection: Detection) -> DetectionCategory {
    switch detection.confidence {
    case 0.65...:
      return .autoConfirm
    case 0.35..<0.65:
      return .askUser(alternatives: [])
    default:
      return .possibleItem
    }
  }
}
