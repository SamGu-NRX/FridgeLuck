import Foundation
import GRDB

// Replay runner: executes one history under one policy arm on a fresh
// file-backed database, recording every auto-correction decision against
// the history's truth, plus restart and database-reopen agreement checks.

struct ScanDecision: Codable {
  let i: Int
  let truth: Int64
  let label: String
  let decision: Int64?
}

struct SeedResult: Codable {
  let family: String
  let seed: Int
  let arm: String
  let decisions: [ScanDecision]
  var restartAgreement: Bool  // set post-run by runWithChecks
  let dbReopenAgreement: Bool
  var wrongAuto: Int = 0
  var correctAuto: Int = 0
  var abstained: Int = 0
}

struct ArmSummary: Codable {
  let arm: String
  let family: String
  let seeds: Int
  let scans: Int
  let wrongAuto: Int
  let correctAuto: Int
  let abstained: Int
  let restartAgreementFailures: Int
  let dbReopenAgreementFailures: Int
}

struct ReplayOutput: Codable {
  let schema: Int
  let arms: [String]
  let results: [SeedResult]
  let summaries: [ArmSummary]
}

enum ReplayRunner {
  /// Execute one history. `withRestarts == false` skips restart events and
  /// keeps one service instance for the whole run (the no-restart twin used
  /// for the cache/database restart-agreement check).
  static func run(history: History, arm: String, withRestarts: Bool, directory: URL) throws
    -> (SeedResult, liveDecision: Int64?)
  {
    let path = directory.appendingPathComponent("\(arm)-\(history.family)-\(history.seed)-\(withRestarts ? "r" : "c").sqlite").path
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: path + suffix)
    }
    var productIds = history.products.wrongPool
    productIds.append(history.products.a)
    productIds.append(history.products.b)
    let queue = try ReplayDatabase.make(path: path, productIds: productIds)
    let policy = try PolicyFactory.make(arm: arm, queue: queue)
    defer { try? queue.close() }

    var decisions: [ScanDecision] = []
    for event in history.events {
      try ReplayDatabase.setClock(queue, to: event.t)
      switch event.type {
      case "scan":
        let decision = try policy.autoCorrect(for: event.label ?? history.focal)
        decisions.append(
          ScanDecision(
            i: event.i,
            truth: event.truth ?? 0,
            label: event.label ?? history.focal,
            decision: decision))
      case "feedback":
        // Feedback applies to the focal label (the Vision label of the scan
        // being reviewed); normalization makes variant renderings one key.
        try policy.recordCorrection(label: history.focal, product: event.product ?? 0)
      case "restart":
        if withRestarts { try policy.restart() }
      case "delay":
        break
      default:
        throw ReplayError.unknownEventType(event.type)
      }
    }

    let live = try policy.autoCorrect(for: history.focal)
    let reopened: Int64?
    if let current = policy as? CurrentPolicy {
      reopened = try current.reopenDecision(for: history.focal, path: path)
    } else {
      let freshQueue = try DatabaseQueue(path: path)
      defer { try? freshQueue.close() }
      let freshPolicy = try PolicyFactory.make(arm: arm, queue: freshQueue)
      reopened = try freshPolicy.autoCorrect(for: history.focal)
    }
    try policy.close()

    let result = SeedResult(
      family: history.family,
      seed: history.seed,
      arm: arm,
      decisions: decisions,
      restartAgreement: true,
      dbReopenAgreement: live == reopened,
      wrongAuto: 0,
      correctAuto: 0,
      abstained: 0)
    return (Self.finishMetrics(result), live)
  }

  static func runWithChecks(history: History, arm: String, directory: URL) throws -> SeedResult {
    let (withRestarts, _) = try run(history: history, arm: arm, withRestarts: true, directory: directory)
    let (without, _) = try run(history: history, arm: arm, withRestarts: false, directory: directory)
    var result = withRestarts
    result.restartAgreement = Self.decisionsMatch(withRestarts.decisions, without.decisions)
    return result
  }

  static func decisionsMatch(_ a: [ScanDecision], _ b: [ScanDecision]) -> Bool {
    guard a.count == b.count else { return false }
    for (x, y) in zip(a, b) where x.i == y.i {
      if x.decision != y.decision { return false }
    }
    return true
  }

  static func finishMetrics(_ result: SeedResult) -> SeedResult {
    var r = result
    var wrong = 0, correct = 0, abstained = 0
    for d in r.decisions {
      if d.decision == nil { abstained += 1 }
      else if d.decision == d.truth { correct += 1 }
      else { wrong += 1 }
    }
    r.wrongAuto = wrong
    r.correctAuto = correct
    r.abstained = abstained
    return r
  }

  static func runAll(histories: [History], arms: [String], directory: URL) throws -> ReplayOutput {
    var results: [SeedResult] = []
    for arm in arms {
      for history in histories {
        results.append(try runWithChecks(history: history, arm: arm, directory: directory))
      }
    }
    var summaries: [ArmSummary] = []
    for arm in arms {
      for family in Set(histories.map(\.family)).sorted() {
        let rs = results.filter { $0.arm == arm && $0.family == family }
        summaries.append(
          ArmSummary(
            arm: arm,
            family: family,
            seeds: rs.count,
            scans: rs.reduce(0) { $0 + $1.decisions.count },
            wrongAuto: rs.reduce(0) { $0 + $1.wrongAuto },
            correctAuto: rs.reduce(0) { $0 + $1.correctAuto },
            abstained: rs.reduce(0) { $0 + $1.abstained },
            restartAgreementFailures: rs.filter { !$0.restartAgreement }.count,
            dbReopenAgreementFailures: rs.filter { !$0.dbReopenAgreement }.count))
      }
    }
    return ReplayOutput(schema: 1, arms: arms, results: results, summaries: summaries)
  }
}

enum ReplayError: Error {
  case unknownEventType(String)
}
