import CoreGraphics
// Production recognition types are internal to the FridgeLuck module; @testable
// exposes them to this executable. Requires a debug build (swift build without
// -c release), which compiles dependencies with -enable-testing.
@testable import FridgeLuck
import Foundation
import GRDB

// Offline replay of the production OCR recognition arm (iOS VisionService) over
// pre-extracted OCR lines. The flow mirrors
// apps/ios/Capability/Core/Recognition/VisionService.swift, scan(inputs:), OCR
// section, on this branch:
//   1. per line: IngredientLexicon.resolveFromTextDetailed -> exact 0.90 /
//      fuzzy 0.60 (VisionService maps kind == .exact ? ocrExactAuto :
//      ocrExactConfirmMin)
//   2. else catalog IngredientCatalogResolver.resolveFromText -> 0.55, kind .fuzzy
//   3. Detection(source: .ocr, ocrMatchKind, evidenceTokens, bbox)
//   4. per-ingredient dedup: higher confidence wins; tie broken by the same
//      sourcePriority mapping as VisionService
//   5. ConfidenceRouter.categorize buckets
// The Vision classification arm and LearningService corrections are not part of
// this experiment (no user corrections exist offline); Apple Vision itself cannot
// run off-device.

struct LineInput: Decodable {
  let text: String
  let x0: Double
  let y0: Double
  let x1: Double
  let y1: Double
  let conf: Double?
}

struct OCRRecordInput: Decodable {
  let imageId: String
  let code: String?
  let role: String?
  let width: Double?
  let height: Double?
  let lines: [LineInput]

  enum CodingKeys: String, CodingKey {
    case imageId = "image_id"
    case code, role, width, height, lines
  }
}

struct TargetTextInput: Decodable {
  let text: String
  let tier: String?
}

struct TargetRecordInput: Decodable {
  let imageId: String
  let texts: [TargetTextInput]

  enum CodingKeys: String, CodingKey {
    case imageId = "image_id"
    case texts
  }
}

struct DetectionOutput: Encodable {
  let ingredientId: Int64
  let label: String
  let confidence: Double
  let bucket: String
  let kind: String
  let matchedToken: String
  let originalText: String
  let boundingBox: [Double]?

  enum CodingKeys: String, CodingKey {
    case ingredientId = "ingredient_id"
    case label, confidence, bucket, kind
    case matchedToken = "matched_token"
    case originalText = "original_text"
    case boundingBox = "bounding_box"
  }
}

struct RecordOutput: Encodable {
  let imageId: String
  let detections: [DetectionOutput]
  let autoCount: Int
  let confirmCount: Int
  let possibleCount: Int
  let lineCount: Int

  enum CodingKeys: String, CodingKey {
    case imageId = "image_id"
    case detections
    case autoCount = "auto_count"
    case confirmCount = "confirm_count"
    case possibleCount = "possible_count"
    case lineCount = "line_count"
  }
}

struct TargetOutput: Encodable {
  let imageId: String
  let targets: [TargetResolution]

  enum CodingKeys: String, CodingKey {
    case imageId = "image_id"
    case targets
  }
}

struct TargetResolution: Encodable {
  let text: String
  let tier: String?
  let ingredientId: Int64?
  let kind: String?
  let matchedToken: String?

  enum CodingKeys: String, CodingKey {
    case text, tier
    case ingredientId = "ingredient_id"
    case kind
    case matchedToken = "matched_token"
  }
}

// Same mapping as VisionService.sourcePriority (ocr exact 2 > fuzzy 1; manual 3 and
// vision 0 included for completeness).
func sourcePriority(_ detection: Detection) -> Int {
  switch detection.source {
  case .manual: return 3
  case .ocr:
    switch detection.ocrMatchKind ?? .exact {
    case .exact: return 2
    case .fuzzy: return 1
    }
  case .vision: return 0
  }
}

func normalizedBoundingBox(_ line: LineInput, width: Double?, height: Double?) -> CGRect? {
  guard let width, let height, width > 0, height > 0 else { return nil }
  let x = line.x0 / width
  let y = 1 - line.y1 / height  // Vision reports bottom-left origin, unit space
  let w = (line.x1 - line.x0) / width
  let h = (line.y1 - line.y0) / height
  return CGRect(x: x, y: y, width: w, height: h)
}

func bucketName(_ detection: Detection) -> String {
  switch ConfidenceRouter.bucket(for: detection) {
  case .auto: return "auto"
  case .confirm: return "confirm"
  case .possible: return "possible"
  }
}

func resolveDetailed(_ text: String, resolver: IngredientCatalogResolver) -> (Int64, Float, OCRMatchKind, String)? {
  if let m = IngredientLexicon.resolveFromTextDetailed(text) {
    let confidence: Float =
      m.kind == .exact
      ? ConfidenceRouter.Thresholds.ocrExactAuto
      : ConfidenceRouter.Thresholds.ocrExactConfirmMin
    return (m.ingredientId, confidence, m.kind, m.matchedToken)
  }
  if let id = resolver.resolveFromText(text) {
    return (id, ConfidenceRouter.Thresholds.ocrFuzzyConfirmMin, .fuzzy, text)
  }
  return nil
}

func processOCRRecord(_ record: OCRRecordInput, resolver: IngredientCatalogResolver) -> RecordOutput {
  var resolved: [(Int64, Float, OCRMatchKind, String, String, CGRect?)] = []
  for line in record.lines {
    guard !line.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let r = resolveDetailed(line.text, resolver: resolver) {
      resolved.append((r.0, r.1, r.2, r.3, line.text, normalizedBoundingBox(line, width: record.width, height: record.height)))
    }
  }

  var detections: [Detection] = resolved.map { ingredientId, confidence, kind, matchedToken, originalText, bbox in
    Detection(
      ingredientId: ingredientId,
      label: resolver.displayName(for: ingredientId) ?? IngredientLexicon.displayName(for: ingredientId),
      confidence: confidence,
      source: .ocr,
      originalVisionLabel: originalText,
      alternatives: [],
      normalizedBoundingBox: bbox,
      evidenceTokens: [matchedToken],
      cropID: nil,
      captureIndex: 0,
      ocrMatchKind: kind
    )
  }

  // Identical dedup to VisionService.bestDetectionByIngredient.
  var bestDetectionByIngredient: [Int64: Detection] = [:]
  for candidate in detections {
    guard let existing = bestDetectionByIngredient[candidate.ingredientId] else {
      bestDetectionByIngredient[candidate.ingredientId] = candidate
      continue
    }
    let keepCandidate: Bool
    if candidate.confidence == existing.confidence {
      keepCandidate = sourcePriority(candidate) > sourcePriority(existing)
    } else {
      keepCandidate = candidate.confidence > existing.confidence
    }
    if keepCandidate {
      bestDetectionByIngredient[candidate.ingredientId] = candidate
    }
  }
  detections = bestDetectionByIngredient.values.sorted { $0.confidence > $1.confidence }

  let categorized = ConfidenceRouter.categorize(detections)

  let outputs = detections.map { d in
    DetectionOutput(
      ingredientId: d.ingredientId,
      label: d.label,
      confidence: Double(d.confidence),
      bucket: bucketName(d),
      kind: (d.ocrMatchKind ?? .exact).rawValue,
      matchedToken: d.evidenceTokens.first ?? "",
      originalText: d.originalVisionLabel,
      boundingBox: d.normalizedBoundingBox.map { [$0.minX, $0.minY, $0.width, $0.height] }
    )
  }

  return RecordOutput(
    imageId: record.imageId,
    detections: outputs,
    autoCount: categorized.confirmed.count,
    confirmCount: categorized.needsConfirmation.count,
    possibleCount: categorized.possible.count,
    lineCount: record.lines.count
  )
}

func processTargetRecord(_ record: TargetRecordInput, resolver: IngredientCatalogResolver) -> TargetOutput {
  let targets = record.texts.map { entry -> TargetResolution in
    if let r = resolveDetailed(entry.text, resolver: resolver) {
      return TargetResolution(text: entry.text, tier: entry.tier, ingredientId: r.0, kind: r.2.rawValue, matchedToken: r.3)
    }
    return TargetResolution(text: entry.text, tier: entry.tier, ingredientId: nil, kind: nil, matchedToken: nil)
  }
  return TargetOutput(imageId: record.imageId, targets: targets)
}

// --- CLI ---
var catalogPath: String?
var inputPath: String?
var outputPath: String?
var mode = "ocr"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
  let flag = args.removeFirst()
  switch flag {
  case "--catalog": catalogPath = args.isEmpty ? nil : args.removeFirst()
  case "--input": inputPath = args.isEmpty ? nil : args.removeFirst()
  case "--output": outputPath = args.isEmpty ? nil : args.removeFirst()
  case "--mode": mode = args.isEmpty ? mode : args.removeFirst()
  default:
    FileHandle.standardError.write(Data("unknown arg \(flag)\n".utf8))
  }
}
guard let catalogPath, let inputPath, let outputPath else {
  FileHandle.standardError.write(Data("usage: GroceryOCRHarness --catalog <sqlite> --input <jsonl> --output <jsonl> [--mode ocr|targets]\n".utf8))
  exit(2)
}

let db = try DatabaseQueue(path: catalogPath)
let resolver = IngredientCatalogResolver(db: db)

let inURL = URL(fileURLWithPath: inputPath)
let outURL = URL(fileURLWithPath: outputPath)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

switch mode {
case "targets":
  let decoder = JSONDecoder()
  try? FileManager.default.removeItem(atPath: outputPath)
  FileManager.default.createFile(atPath: outputPath, contents: nil)
  let handle = try FileHandle(forWritingTo: outURL)
  // URL.lines is Apple-only; Linux Foundation gets the file contents as a String.
  let contents = try String(contentsOf: inURL, encoding: .utf8)
  for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let record = try decoder.decode(TargetRecordInput.self, from: Data(line.utf8))
    let out = processTargetRecord(record, resolver: resolver)
    var data = try encoder.encode(out)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }
  try handle.close()
default:
  let decoder = JSONDecoder()
  try? FileManager.default.removeItem(atPath: outputPath)
  FileManager.default.createFile(atPath: outputPath, contents: nil)
  let handle = try FileHandle(forWritingTo: outURL)
  let contents = try String(contentsOf: inURL, encoding: .utf8)
  for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let record = try decoder.decode(OCRRecordInput.self, from: Data(line.utf8))
    let out = processOCRRecord(record, resolver: resolver)
    var data = try encoder.encode(out)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }
  try handle.close()
}
