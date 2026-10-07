import CoreGraphics
import FLFeatureLogic
import Foundation

typealias ScanRequestFailure = FLFeatureLogic.ScanRequestFailure

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
  let requestFailures: [ScanRequestFailure]
  // Travels through the existing recordRun diagnostics argument without changing its closure.
  let outcome: ScanRunRecord.Outcome

  init(
    captureCount: Int, cropCount: Int, topRawLabels: [String], ocrCandidates: [String],
    bucketCounts: ScanBucketCounts, passErrors: [String], elapsedMs: Int,
    requestFailures: [ScanRequestFailure] = [], outcome: ScanRunRecord.Outcome = .completed
  ) {
    self.captureCount = captureCount
    self.cropCount = cropCount
    self.topRawLabels = topRawLabels
    self.ocrCandidates = ocrCandidates
    self.bucketCounts = bucketCounts
    self.passErrors = passErrors
    self.elapsedMs = elapsedMs
    self.requestFailures = requestFailures
    self.outcome = outcome
  }

  private enum CodingKeys: String, CodingKey {
    case captureCount, cropCount, topRawLabels, ocrCandidates, bucketCounts, passErrors, elapsedMs, requestFailures, outcome
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    outcome = try values.decodeIfPresent(ScanRunRecord.Outcome.self, forKey: .outcome) ?? .completed
    captureCount = try values.decode(Int.self, forKey: .captureCount)
    cropCount = try values.decode(Int.self, forKey: .cropCount)
    topRawLabels = try values.decode([String].self, forKey: .topRawLabels)
    ocrCandidates = try values.decode([String].self, forKey: .ocrCandidates)
    bucketCounts = try values.decode(ScanBucketCounts.self, forKey: .bucketCounts)
    passErrors = try values.decode([String].self, forKey: .passErrors)
    elapsedMs = try values.decode(Int.self, forKey: .elapsedMs)
    requestFailures = try values.decodeIfPresent([ScanRequestFailure].self, forKey: .requestFailures) ?? []
  }

  var classificationFailureCount: Int {
    requestFailures.filter { $0.kind == .classification }.count
  }

  var ocrFailureCount: Int {
    requestFailures.filter { $0.kind == .ocr }.count
  }

  static func requestFailures(
    captureIndex: Int, cropID: String, classificationError: Error?, ocrError: Error?
  ) -> [ScanRequestFailure] {
    var failures: [ScanRequestFailure] = []
    if let classificationError {
      failures.append(.init(
        captureIndex: captureIndex, cropID: cropID, kind: .classification,
        message: String(describing: classificationError)))
    }
    if let ocrError {
      failures.append(.init(
        captureIndex: captureIndex, cropID: cropID, kind: .ocr,
        message: String(describing: ocrError)))
    }
    return failures
  }

  /// Benchmark validity still depends on both requests failing on a crop, not either request alone.
  static func cropPassErrors(
    captureIndex: Int, cropID: String, classificationError: Error?, ocrError: Error?
  ) -> [String] {
    guard let classificationError, let ocrError else { return [] }
    return ["capture=\(captureIndex),crop=\(cropID):class=\(String(describing: classificationError)),ocr=\(String(describing: ocrError))"]
  }
}

enum ScanDemoGate {
  static let benchmarkIterations = 5
  static let minJaccardForStability = 0.80
  static let targetThreeShotMedianMs = 8_000
}
