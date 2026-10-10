// Generated from ScanContracts.swift by Scripts/sync_sources.py -- do not edit.
// Only the enums Detection/ConfidenceRouter need; the full file pulls in
// CoreGraphics and FLFeatureLogic.

enum OCRMatchKind: String, Sendable, Codable {
  case exact
  case fuzzy
}

enum ConfidenceBucket: String, Sendable, Codable {
  case auto
  case confirm
  case possible
}
