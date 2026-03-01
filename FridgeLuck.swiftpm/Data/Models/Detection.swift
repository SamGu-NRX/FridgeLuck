import CoreGraphics
import Foundation

// MARK: - Detection Source

enum DetectionSource: String, Sendable, Codable {
  case vision
  case ocr
  case manual
}

// MARK: - Detection Alternative

struct DetectionAlternative: Identifiable, Sendable, Hashable {
  let ingredientId: Int64
  let label: String
  let confidence: Float?

  var id: Int64 { ingredientId }
}

// MARK: - Detection

struct Detection: Identifiable, Sendable {
  let id = UUID()
  let ingredientId: Int64
  let label: String
  let confidence: Float
  let source: DetectionSource
  let originalVisionLabel: String
  var alternatives: [DetectionAlternative] = []
  var normalizedBoundingBox: CGRect? = nil
  var evidenceTokens: [String] = []
  var cropID: String? = nil
  var captureIndex: Int? = nil
  var ocrMatchKind: OCRMatchKind? = nil

  var isHighConfidence: Bool { ConfidenceRouter.bucket(for: self) == .auto }
  var isMediumConfidence: Bool { ConfidenceRouter.bucket(for: self) == .confirm }
  var isLowConfidence: Bool { ConfidenceRouter.bucket(for: self) == .possible }
}

// MARK: - Detection Category

enum DetectionCategory: Sendable {
  case autoConfirm
  case askUser(alternatives: [String])
  case possibleItem

  static func categorize(_ detection: Detection) -> DetectionCategory {
    switch ConfidenceRouter.bucket(for: detection) {
    case .auto:
      return .autoConfirm
    case .confirm:
      return .askUser(alternatives: [])
    case .possible:
      return .possibleItem
    }
  }
}
