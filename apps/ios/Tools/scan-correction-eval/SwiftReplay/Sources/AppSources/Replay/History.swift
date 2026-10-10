import Foundation

// History decoding: matches data/histories.json (schema 1) from sequences.py.

struct FamilyInfo: Decodable {
  let name: String
  let kind: String
  let seedCount: Int
  let eventCounts: EventCounts

  enum CodingKeys: String, CodingKey {
    case name, kind
    case seedCount = "seed_count"
    case eventCounts = "event_counts"
  }
}

struct EventCounts: Decodable {
  let scan: Int
  let feedback: Int
  let restart: Int
  let delay: Int
}

struct ProductPool: Decodable {
  let a: Int64
  let b: Int64
  let wrongPool: [Int64]

  enum CodingKeys: String, CodingKey {
    case a, b
    case wrongPool = "wrong_pool"
  }
}

struct HistoryEvent: Decodable {
  let i: Int
  let t: Int
  let type: String
  let truth: Int64?
  let conf: Double?
  let label: String?
  let product: Int64?
  let user: String?
  let days: Int?
}

struct History: Decodable {
  let family: String
  let seed: Int
  let focal: String
  let products: ProductPool
  let events: [HistoryEvent]
}

struct HistoriesFile: Decodable {
  let schema: Int
  let families: [FamilyInfo]
  let developmentFamilies: [String]
  let heldoutFamily: String
  let histories: [History]

  enum CodingKeys: String, CodingKey {
    case schema, families, histories
    case developmentFamilies = "development_families"
    case heldoutFamily = "heldout_family"
  }
}

struct ExpectedScanRecord: Decodable {
  let i: Int
  let t: Int
  let truth: Int64
  let label: String
  let decision: Int64?
}

struct ExpectedFile: Decodable {
  let schema: Int
  let policy: String
  let seeds: [String: [ExpectedScanRecord]]
  let summaries: [String: ExpectedSummary]

  enum CodingKeys: String, CodingKey {
    case schema, policy, seeds
    case summaries
  }
}

struct ExpectedSummary: Decodable {
  let scans: Int
  let wrongAuto: Int
  let correctAuto: Int
  let abstained: Int

  enum CodingKeys: String, CodingKey {
    case scans
    case wrongAuto = "wrong_auto"
    case correctAuto = "correct_auto"
    case abstained
  }
}
