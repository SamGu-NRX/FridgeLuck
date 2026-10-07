import Foundation

struct ScanRunDetectionRecord: Identifiable, Sendable, Codable {
  let id: UUID
  let ingredientId: Int64
  let label: String
  let source: DetectionSource
  let confidenceScore: Float
  let bucket: ConfidenceBucket
  let ocrMatchKind: OCRMatchKind?
  let cropID: String?
  let captureIndex: Int?
  let evidenceTokens: [String]

  init(detection: Detection) {
    self.id = detection.id
    self.ingredientId = detection.ingredientId
    self.label = detection.label
    self.source = detection.source
    self.confidenceScore = detection.confidence
    self.bucket = ConfidenceRouter.bucket(for: detection)
    self.ocrMatchKind = detection.ocrMatchKind
    self.cropID = detection.cropID
    self.captureIndex = detection.captureIndex
    self.evidenceTokens = detection.evidenceTokens
  }
}

struct ScanRunRecord: Identifiable, Sendable, Codable {
  enum RunMode: String, Sendable, Codable {
    case live
    case demo
  }

  let outcome: ScanOutcome
  let id: UUID
  let createdAt: Date
  let runMode: RunMode
  let inputSources: [ScanInputSource]
  let provenance: ScanProvenance
  let captureCount: Int
  let cropCount: Int
  let elapsedMs: Int
  let bucketCounts: ScanBucketCounts
  let passErrors: [String]
  let detections: [ScanRunDetectionRecord]
  let requestFailures: [ScanRequestFailure]

  init(
    id: UUID,
    createdAt: Date,
    runMode: RunMode,
    inputSources: [ScanInputSource],
    provenance: ScanProvenance,
    captureCount: Int,
    cropCount: Int,
    elapsedMs: Int,
    bucketCounts: ScanBucketCounts,
    passErrors: [String],
    detections: [ScanRunDetectionRecord],
    requestFailures: [ScanRequestFailure] = [],
    outcome: ScanOutcome = .completed
  ) {
    self.outcome = outcome
    self.id = id
    self.createdAt = createdAt
    self.runMode = runMode
    self.inputSources = inputSources
    self.provenance = provenance
    self.captureCount = captureCount
    self.cropCount = cropCount
    self.elapsedMs = elapsedMs
    self.bucketCounts = bucketCounts
    self.passErrors = passErrors
    self.detections = detections
    self.requestFailures = requestFailures
  }

  private enum CodingKeys: String, CodingKey {
    case id, createdAt, runMode, inputSources, provenance, captureCount, cropCount, elapsedMs, bucketCounts, passErrors, detections, requestFailures, outcome
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // History written before outcomes were recorded contains completed scans only.
    outcome = try values.decodeIfPresent(ScanOutcome.self, forKey: .outcome) ?? .completed
    id = try values.decode(UUID.self, forKey: .id)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    runMode = try values.decode(RunMode.self, forKey: .runMode)
    inputSources = try values.decode([ScanInputSource].self, forKey: .inputSources)
    provenance = try values.decode(ScanProvenance.self, forKey: .provenance)
    captureCount = try values.decode(Int.self, forKey: .captureCount)
    cropCount = try values.decode(Int.self, forKey: .cropCount)
    elapsedMs = try values.decode(Int.self, forKey: .elapsedMs)
    bucketCounts = try values.decode(ScanBucketCounts.self, forKey: .bucketCounts)
    passErrors = try values.decode([String].self, forKey: .passErrors)
    detections = try values.decode([ScanRunDetectionRecord].self, forKey: .detections)
    requestFailures = try values.decodeIfPresent([ScanRequestFailure].self, forKey: .requestFailures) ?? []
  }

  static func failureInputs(
    error: Error, captureCount: Int, elapsedMs: Int
  ) -> (diagnostics: ScanDiagnostics, detections: [Detection])? {
    guard !(error is CancellationError) else { return nil }
    let pipelineError = error as? VisionService.VisionServiceError
    let failures = pipelineError?.requestFailures ?? []
    // A failed pipeline reports both requests per crop. Count each crop once.
    let cropCount = Dictionary(grouping: failures, by: \.captureIndex).values.reduce(0) {
      $0 + Set($1.map(\.cropID)).count
    }
    let diagnostics = ScanDiagnostics(
      captureCount: captureCount, cropCount: cropCount, topRawLabels: [], ocrCandidates: [],
      bucketCounts: .init(auto: 0, confirm: 0, possible: 0),
      passErrors: pipelineError?.passErrors ?? [], elapsedMs: elapsedMs,
      requestFailures: failures, outcome: .failed(message: error.localizedDescription))
    return (diagnostics, [])
  }

  var classificationFailureCount: Int {
    requestFailures.filter { $0.kind == .classification }.count
  }

  var ocrFailureCount: Int {
    requestFailures.filter { $0.kind == .ocr }.count
  }
}

actor ScanRunStore {
  private let fileURL: URL
  private let maxRecords: Int

  init(maxRecords: Int = 80, fileURL: URL? = nil) {
    self.maxRecords = maxRecords
    self.fileURL = fileURL ?? ScanRunStore.resolveFileURL()
  }

  func record(
    mode: ScanRunRecord.RunMode,
    inputSources: [ScanInputSource],
    provenance: ScanProvenance,
    diagnostics: ScanDiagnostics?,
    detections: [Detection]
  ) async {
    var all = await load()
    let derivedBuckets = ConfidenceRouter.categorize(detections)
    let record = ScanRunRecord(
      id: UUID(),
      createdAt: Date(),
      runMode: mode,
      inputSources: inputSources,
      provenance: provenance,
      captureCount: diagnostics?.captureCount ?? max(1, inputSources.count),
      cropCount: diagnostics?.cropCount ?? 0,
      elapsedMs: diagnostics?.elapsedMs ?? 0,
      bucketCounts: diagnostics?.bucketCounts
        ?? ScanBucketCounts(
          auto: derivedBuckets.confirmed.count,
          confirm: derivedBuckets.needsConfirmation.count,
          possible: derivedBuckets.possible.count
        ),
      passErrors: diagnostics?.passErrors ?? [],
      detections: detections.map(ScanRunDetectionRecord.init(detection:)),
      requestFailures: diagnostics?.requestFailures ?? [],
      outcome: diagnostics?.outcome ?? .completed
    )

    all.insert(record, at: 0)
    if all.count > maxRecords {
      all = Array(all.prefix(maxRecords))
    }
    await save(all)
  }

  func recent(limit: Int = 30) async -> [ScanRunRecord] {
    Array((await load()).prefix(limit))
  }

  func clear() async {
    await save([])
  }

  private func load() async -> [ScanRunRecord] {
    guard
      let data = try? Data(contentsOf: fileURL)
    else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let records = try? decoder.decode([ScanRunRecord].self, from: data) else {
      return []
    }
    return records
  }

  private func save(_ records: [ScanRunRecord]) async {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(records)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // Non-fatal diagnostics storage.
    }
  }

  static func benchmarkOutputURL() -> URL {
    resolveDirectoryURL().appendingPathComponent("scan_benchmark_latest.json")
  }

  private static func resolveFileURL() -> URL {
    resolveDirectoryURL().appendingPathComponent("scan_run_records.json")
  }

  private static func resolveDirectoryURL() -> URL {
    let fm = FileManager.default
    let base =
      fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fm.temporaryDirectory
    let directory = base.appendingPathComponent("FridgeLuck", isDirectory: true)
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
