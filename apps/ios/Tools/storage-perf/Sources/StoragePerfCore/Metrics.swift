import Foundation
import GRDB

// MARK: - Measurement helpers
//
// Timing is wall-clock CPU-independent ContinuousClock, rounded to whole
// microseconds (integers — safe for byte-reproducible summaries). Memory comes
// from /proc/self/status (Linux); Apple-device reruns would use task_info.

struct MemoryReading: Equatable {
  /// False when RSS could not be measured (missing /proc, unparsable status).
  /// A report never presents zeros as measurements.
  var available: Bool
  var vmRssKB: Int64?
  var vmHwmKB: Int64?
}

enum Metrics {
  /// Parses /proc/self/status content for VmRSS/VmHWM. Linux separates the
  /// key from the value with a TAB followed by spaces — split on any
  /// whitespace, not just " ". Returns nil values when either field is
  /// missing, unparsable, or zero (a live process never has zero RSS).
  static func parseMemoryStatus(_ status: String) -> MemoryReading {
    var rss: Int64?
    var hwm: Int64?
    for line in status.split(separator: "\n") {
      let parts = line.split(whereSeparator: { $0.isWhitespace })
      guard parts.count >= 2, parts[0].hasSuffix(":") else { continue }
      let key = String(parts[0].dropLast())
      let value = Int64(parts[1])
      switch key {
      case "VmRSS": rss = value
      case "VmHWM": hwm = value
      default: break
      }
    }
    // Treat "present but zero" (or absent) as unmeasured, not as a reading.
    if let r = rss, r > 0, let h = hwm, h > 0 {
      return MemoryReading(available: true, vmRssKB: r, vmHwmKB: h)
    }
    return MemoryReading(available: false, vmRssKB: nil, vmHwmKB: nil)
  }

  static func memory() -> MemoryReading {
    let status = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
    return parseMemoryStatus(status)
  }

  /// Times one closure run in whole microseconds.
  static func timeUs(_ body: () throws -> Void) rethrows -> Int64 {
    let clock = ContinuousClock()
    let start = clock.now
    try body()
    let elapsed = clock.now - start
    let us =
      elapsed.components.seconds * 1_000_000
      + elapsed.components.attoseconds / 1_000_000_000_000
    return us
  }

  // MARK: SQLite conditions

  static func sqliteConditions(db: Database) -> [(String, String)] {
    var conditions: [(String, String)] = []
    for pragma in ["journal_mode", "page_size", "cache_size", "locking_mode", "synchronous"] {
      let value = try? String.fetchOne(db, sql: "PRAGMA \(pragma)")
      conditions.append((pragma, value ?? "unknown"))
    }
    let pageCount = try? Int64.fetchOne(db, sql: "PRAGMA page_count")
    conditions.append(("page_count", pageCount.map(String.init) ?? "unknown"))
    let freelist = try? Int64.fetchOne(db, sql: "PRAGMA freelist_count")
    conditions.append(("freelist_count", freelist.map(String.init) ?? "unknown"))
    let sqliteVersion = try? String.fetchOne(db, sql: "SELECT sqlite_version()")
    conditions.append(("sqlite_version", sqliteVersion ?? "unknown"))
    return conditions
  }

  // MARK: Plans

  static func explainQueryPlan(
    db: Database, sql: String, arguments: [Any?]
  ) throws -> [PlanRow] {
    let rows = try Row.fetchAll(
      db, sql: "EXPLAIN QUERY PLAN " + sql,
      arguments: StatementArguments(arguments))
    return rows.map { row in
      PlanRow(
        selectid: row["selectid"] ?? 0,
        order: row["order"] ?? 0,
        from: row["from"] ?? 0,
        detail: row["detail"] ?? "")
    }
  }

  static func planJson(_ rows: [PlanRow]) -> JSON {
    .array(rows.map { row in
      .object([
        ("selectid", JSON.int(Int64(row.selectid))),
        ("order", JSON.int(Int64(row.order))),
        ("from", JSON.int(Int64(row.from))),
        ("detail", JSON.string(row.detail)),
      ])
    })
  }

  // MARK: Timing distributions

  /// Runs warm-up passes (recorded separately), then timed iterations.
  static func measure(
    warmup: Int, iterations: Int, _ body: () throws -> Void
  ) rethrows -> (warmupUs: [Int64], iterationsUs: [Int64]) {
    var warmupUs: [Int64] = []
    for _ in 0..<warmup {
      warmupUs.append(try timeUs(body))
    }
    var iterationsUs: [Int64] = []
    for _ in 0..<iterations {
      iterationsUs.append(try timeUs(body))
    }
    return (warmupUs, iterationsUs)
  }

  /// Distribution summary over a timing list, in whole microseconds.
  /// p-values are nearest-rank percentiles over the sorted samples.
  static func distribution(_ samples: [Int64]) -> JSON {
    let sorted = samples.sorted()
    func percentile(_ p: Double) -> Int64 {
      guard !sorted.isEmpty else { return 0 }
      let rank = Int((p / 100.0) * Double(sorted.count - 1) + 0.5)
      return sorted[min(max(rank, 0), sorted.count - 1)]
    }
    let mean = sorted.isEmpty ? 0 : (sorted.reduce(0 as Int64, +)) / Int64(sorted.count)
    return .object([
      ("min", JSON.int(sorted.first ?? 0)),
      ("p50", JSON.int(percentile(50))),
      ("p90", JSON.int(percentile(90))),
      ("p99", JSON.int(percentile(99))),
      ("max", JSON.int(sorted.last ?? 0)),
      ("mean", JSON.int(mean)),
      ("samples", JSON.int(Int64(sorted.count))),
    ])
  }
}

// MARK: - StatementArguments from [Any?]

extension StatementArguments {
  init(_ values: [Any?]) {
    // GRDB's positional init takes [DatabaseValueConvertible?]; wrap Any?
    // values that the harness controls (Int/Int64/Double/String/Bool/nil).
    let wrapped: [DatabaseValueConvertible?] = values.map { value in
      switch value {
      case .none: return nil
      case let v as Int64: return v
      case let v as Int: return Int64(v)
      case let v as Double: return v
      case let v as String: return v
      case let v as Bool: return v
      default:
        fatalError("unsupported plan argument type: \(type(of: value))")
      }
    }
    self.init(wrapped)
  }
}
