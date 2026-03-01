import CoreGraphics
import Foundation

enum ScanInputSource: String, Sendable, Codable {
  case camera
  case photoLibrary
  case demo
  case benchmark
}

struct ScanInput: Sendable {
  let image: CGImage
  let source: ScanInputSource
  let captureIndex: Int
}

enum ScanProvenance: String, Sendable, Codable {
  case realScan
  case bundledFixture
  case starterFallback
}

enum OCRMatchKind: String, Sendable, Codable {
  case exact
  case fuzzy
}

enum ConfidenceBucket: String, Sendable, Codable {
  case auto
  case confirm
  case possible
}

struct ScanBucketCounts: Sendable, Codable {
  let auto: Int
  let confirm: Int
  let possible: Int
}

struct ScanDiagnostics: Sendable, Codable {
  let captureCount: Int
  let cropCount: Int
  let topRawLabels: [String]
  let ocrCandidates: [String]
  let bucketCounts: ScanBucketCounts
  let passErrors: [String]
  let elapsedMs: Int
}

enum ScanDemoGate {
  static let benchmarkIterations = 5
  static let minJaccardForStability = 0.80
  static let targetThreeShotMedianMs = 8_000
}
