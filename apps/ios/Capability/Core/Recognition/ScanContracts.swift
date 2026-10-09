// CoreGraphics exists on iOS/macOS; Linux supplies the geometry types through
// Foundation instead, so the import is guarded there.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

enum ScanInputSource: String, Sendable, Codable {
  case camera
  case photoLibrary
  case demo
  case benchmark
}

// ScanInput carries a CoreGraphics image and is only constructed by the iOS
// camera pipeline; it is not part of the Linux logic build. Everything below
// it is platform-neutral.
#if canImport(CoreGraphics)
struct ScanInput: Sendable {
  let image: CGImage
  let source: ScanInputSource
  let captureIndex: Int
}
#endif

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
