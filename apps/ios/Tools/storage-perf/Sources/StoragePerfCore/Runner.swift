import Foundation
import GRDB

// MARK: - Sweep runner
//
// For each (profile, scale): seed a database through the real migrations, run
// the real repository reads with warm-up, capture per-iteration timings, query
// plans, SQLite conditions, file/WAL sizes, and peak memory; then delete the
// database (results keep aggregates only — never database bytes).

public struct RunnerOptions {
  public var seed: UInt64 = 20261010
  public var profiles: [WorkloadProfile] = WorkloadProfile.allCases
  public var scales: [Int] = workloadScales
  public var warmup = 3
  public var iterations = 15
  public var experiments = true

  public init(
    seed: UInt64 = 20261010, profiles: [WorkloadProfile] = WorkloadProfile.allCases,
    scales: [Int] = workloadScales, warmup: Int = 3, iterations: Int = 15,
    experiments: Bool = true
  ) {
    self.seed = seed
    self.profiles = profiles
    self.scales = scales
    self.warmup = warmup
    self.iterations = iterations
    self.experiments = experiments
  }
}

public enum Runner {
  public static func runSweep(options: RunnerOptions) throws -> JSON {
    let scratchRoot =
      NSTemporaryDirectory() + "/storage-perf-\(UInt64.random(in: 0..<UInt64.max))"
    var profileResults: [(String, JSON)] = []

    for profile in options.profiles {
      var scaleResults: [(String, JSON)] = []
      for scale in options.scales {
        let scratch = scratchRoot + "/\(profile.label)_x\(scale)"
        let seeded = try WorkloadSeeder.makeSeeded(
          profile: profile, scale: scale, seed: options.seed,
          directory: scratch, name: "workload")
        let runResult = try runReads(on: seeded, options: options)
        scaleResults.append((
          "x\(scale)",
          .object([
            ("counts", countsJson(seeded.counts)),
            ("seedDurationUs", JSON.int(Int64(seeded.seedDurationSeconds * 1_000_000))),
            ("fileSizeBytesAfterSeed", JSON.int(seeded.fileSizeBytes)),
            ("walSizeBytesAfterSeed", JSON.int(seeded.walSizeBytes)),
            ("sqlite", runResult.sqlite),
            ("reads", runResult.reads),
            ("memoryAfterSweep", runResult.memory),
          ])
        ))
        // Tear the disposable database down; nothing but aggregates survives.
        try? FileManager.default.removeItem(atPath: scratch)
      }
      profileResults.append((profile.label, .object(scaleResults)))
    }

    var summaryPairs: [(String, JSON)] = [
      ("schemaVersion", JSON.int(1)),
      ("toolVersion", JSON.int(1)),
      ("seed", JSON.int(Int64(bitPattern: options.seed))),
      ("warmup", JSON.int(Int64(options.warmup))),
      ("iterations", JSON.int(Int64(options.iterations))),
      ("profiles", .object(profileResults)),
    ]

    if options.experiments {
      let experimentScratch = scratchRoot + "/experiments"
      let experimentResults = try IndexExperiments.run(
        directory: experimentScratch, seed: options.seed,
        warmup: options.warmup, iterations: 5)
      summaryPairs.append(("experiments", .object([
        ("scale", JSON.string("five_year_x4")),
        ("results", .array(experimentResults.map(experimentJson))),
      ])))
    }

    return .object(summaryPairs)
  }

  /// Renders the compact canonical body, computes the digest over those exact
  /// bytes, and returns the final text: body with `,"digest":"<hex>"` inserted
  /// before the closing brace. ReportVerifier relies on this exact layout.
  public static func renderReport(withDigest summary: JSON) -> String {
    let body = summary.render
    assert(body.hasSuffix("}"))
    let digest = SHA256.hex(body)
    let head = String(body.dropLast())
    return head + ",\"digest\":\"\(digest)\"}"
  }

  struct ReadRunResult {
    var reads: JSON
    var sqlite: JSON
    var memory: JSON
  }

  private static func runReads(on seeded: SeededDatabase, options: RunnerOptions) throws
    -> ReadRunResult {
    var readResults: [(String, JSON)] = []
    var planResults: [(String, JSON)] = []

    for workload in RepositoryReads.workloads(db: seeded.dbQueue) {
      let iterations = workload.iterations ?? options.iterations
      let (warmupUs, iterationsUs) = try Metrics.measure(
        warmup: options.warmup, iterations: iterations) {
          try workload.run(seeded.dbQueue)
        }
      readResults.append((
        workload.name,
        .object([
          ("warmupUs", .array(warmupUs.map { JSON.int($0) })),
          ("iterationsUs", .array(iterationsUs.map { JSON.int($0) })),
          ("summary", Metrics.distribution(iterationsUs)),
        ])
      ))
    }

    // Plans are captured on a dedicated read pass over the same database.
    try seeded.dbQueue.read { db in
      for mirrored in MirroredQueries.all {
        let rows = try Metrics.explainQueryPlan(
          db: db, sql: mirrored.sql, arguments: mirrored.arguments)
        planResults.append((mirrored.name, Metrics.planJson(rows)))
      }
      return true
    }

    let sqliteJson: JSON = try seeded.dbQueue.read { db in
      .object(Metrics.sqliteConditions(db: db).map { (key, value) in (key, JSON.string(value)) })
    }

    // Growth check: a pure read loop must not grow the database files. Sizes
    // are recorded again after the full read sweep so the summary shows it.
    let fileAfter = WorkloadSeeder.fileSize(seeded.path)
    let walAfter = WorkloadSeeder.fileSize(seeded.path + "-wal")
    readResults.append((
      "_file_growth",
      .object([
        ("fileSizeBytesBeforeReads", JSON.int(seeded.fileSizeBytes)),
        ("fileSizeBytesAfterReads", JSON.int(fileAfter)),
        ("walSizeBytesBeforeReads", JSON.int(seeded.walSizeBytes)),
        ("walSizeBytesAfterReads", JSON.int(walAfter)),
        ("fileGrew", JSON.bool(fileAfter != seeded.fileSizeBytes)),
        ("walGrew", JSON.bool(walAfter != seeded.walSizeBytes)),
      ])
    ))

    let memory = Metrics.memory()
    let memoryJson = JSON.object([
      ("vmRssKB", JSON.int(memory.vmRssKB)),
      ("vmHwmKB", JSON.int(memory.vmHwmKB)),
    ])

    return ReadRunResult(
      reads: .object(readResults),
      sqlite: sqliteJson,
      memory: memoryJson
    )
  }

  private static func countsJson(_ counts: StateCounts) -> JSON {
    .object([
      ("inventory_events", JSON.int(Int64(counts.inventoryEvents))),
      ("inventory_lots", JSON.int(Int64(counts.inventoryLots))),
      ("cooking_history", JSON.int(Int64(counts.meals))),
      ("cooking_history_swaps", JSON.int(Int64(counts.swaps))),
      ("confidence_signal_events", JSON.int(Int64(counts.signals))),
      ("cooking_history_nutrition_snapshots", JSON.int(Int64(counts.snapshots))),
      ("cooking_history_nutrition_lines", JSON.int(Int64(counts.snapshotLines))),
      ("inventory_items", JSON.int(Int64(counts.inventoryItems))),
      ("ingredients", JSON.int(Int64(counts.ingredients))),
      ("recipes", JSON.int(Int64(counts.recipes))),
      ("recipe_ingredients", JSON.int(Int64(counts.recipeIngredients))),
    ])
  }

  static func experimentJson(_ result: ExperimentResult) -> JSON {
    .object([
      ("name", JSON.string(result.name)),
      ("description", JSON.string(result.description)),
      ("alternativeIndex", result.alternativeIndex.map { JSON.string($0) } ?? JSON.null),
      ("exactOutputParity", JSON.bool(result.exactOutputParity)),
      ("nutritionBitParity", JSON.bool(result.nutritionBitParity)),
      ("passes", JSON.bool(result.passes)),
      ("baselinePlan", Metrics.planJson(result.baselinePlan)),
      ("alternativePlan", Metrics.planJson(result.alternativePlan)),
      ("baselineUs", .array(result.baselineUs.map { JSON.int($0) })),
      ("alternativeUs", .array(result.alternativeUs.map { JSON.int($0) })),
      ("notes", JSON.string(result.notes)),
    ])
  }
}

// MARK: - Verifier
//
// ReportVerifier checks a rendered report against the writer's contract:
// compact single-line JSON, digest pair last, digest = SHA-256 over the body
// bytes that precede it. It also validates structural invariants (required
// top-level keys, no NaN/inf artifacts, digest shape). Mutation-control tests
// in StoragePerfTests prove every check actually rejects tampered input.

public enum ReportVerifier {
  public struct Failure: Error, Equatable, CustomStringConvertible {
    public var reason: String
    public init(reason: String) { self.reason = reason }
    public var description: String { reason }
  }

  /// Verifies `text` against the writer contract. Returns the digest hex.
  public static func verify(text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
      throw Failure(reason: "report is not a single JSON object")
    }

    // The digest pair is the last key in the top-level object.
    let marker = ",\"digest\":\""
    guard let markerRange = trimmed.range(of: marker, options: .backwards) else {
      throw Failure(reason: "digest field missing or not last")
    }
    let digestStart = markerRange.upperBound
    // Closing quote of the digest must sit directly before the final brace.
    let closingBrace = trimmed.index(before: trimmed.endIndex)
    let closingQuote = trimmed.index(before: closingBrace)
    guard trimmed[closingQuote] == "\"" else {
      throw Failure(reason: "digest not terminated before closing brace")
    }
    let digest = String(trimmed[digestStart..<closingQuote])
    guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
      throw Failure(reason: "digest is not 64 hex characters")
    }

    let body = String(trimmed[..<markerRange.lowerBound]) + "}"
    let actual = SHA256.hex(body)
    guard actual == digest else {
      throw Failure(reason: "digest mismatch: body changed after signing")
    }

    // Structural invariants over the signed body.
    for key in ["\"schemaVersion\":", "\"seed\":", "\"warmup\":", "\"iterations\":", "\"profiles\":"] {
      guard body.contains(key) else {
        throw Failure(reason: "missing required key \(key)")
      }
    }
    for artifact in ["NaN", "inf", "Infinity", "-0n"] {
      guard !body.contains(artifact) else {
        throw Failure(reason: "forbidden numeric artifact \(artifact) in body")
      }
    }
    return digest
  }
}
