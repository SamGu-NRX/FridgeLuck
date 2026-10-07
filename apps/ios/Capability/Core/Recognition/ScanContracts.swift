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

  var classificationFailureCount: Int {
    passErrors.filter { $0.contains(",request=classification:") }.count
  }

  var ocrFailureCount: Int {
    passErrors.filter { $0.contains(",request=ocr:") }.count
  }

  /// A successful sibling request must not hide a failure. Keep strings so existing
  /// scan records and the report sheet's pass-error count need no format migration.
  static func requestFailures(
    captureIndex: Int,
    cropID: String,
    classificationError: Error?,
    ocrError: Error?
  ) -> [String] {
    var failures: [String] = []
    if let classificationError {
      failures.append(
        "capture=\(captureIndex),crop=\(cropID),request=classification:\(String(describing: classificationError))")
    }
    if let ocrError {
      failures.append(
        "capture=\(captureIndex),crop=\(cropID),request=ocr:\(String(describing: ocrError))")
    }
    return failures
  }
}

enum ScanDemoGate {
  static let benchmarkIterations = 5
  static let minJaccardForStability = 0.80
  static let targetThreeShotMedianMs = 8_000
}
