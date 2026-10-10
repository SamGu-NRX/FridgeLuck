import FLBarcode
import Foundation

/// One line of the committed OFF fixture (`Fixtures/off_products.jsonl`), with the OFF
/// field names preserved verbatim.
public struct OFFFixtureRecord: Codable, Sendable, Equatable {
  public let code: String
  public let productName: String?
  public let brands: String?
  public let quantity: String?
  public let servingSize: String?
  public let ingredientsText: String?

  public init(
    code: String,
    productName: String?,
    brands: String?,
    quantity: String?,
    servingSize: String?,
    ingredientsText: String?
  ) {
    self.code = code
    self.productName = productName
    self.brands = brands
    self.quantity = quantity
    self.servingSize = servingSize
    self.ingredientsText = ingredientsText
  }

  private enum CodingKeys: String, CodingKey {
    case code
    case productName = "product_name"
    case brands
    case quantity
    case servingSize = "serving_size"
    case ingredientsText = "ingredients_text"
  }
}

/// Machine-readable provenance, mirroring `Fixtures/PROVENANCE.json`.
public struct EvalProvenance: Codable, Sendable {
  public let dataset: String
  public let sourceUrls: [String]
  public let retrievedAt: String
  public let license: String
  public let attribution: String
  public let userAgent: String?
  public let fetchCommand: String?
  public let notes: String?
  public let selection: String?
  public let selectedBuckets: [String: Int]?

  private enum CodingKeys: String, CodingKey {
    case dataset, license, attribution, notes, selection
    case sourceUrls = "source_urls"
    case retrievedAt = "retrieved_at"
    case userAgent = "user_agent"
    case fetchCommand = "fetch_command"
    case selectedBuckets = "selected_buckets"
  }
}

public extension EvalProvenance {
  var retrievedAtDate: Date? {
    ISO8601DateFormatter().date(from: retrievedAt)
  }
}

/// One ingredient row of the evaluation catalog slice (`Fixtures/eval-catalog.json`).
public struct EvalCatalogItem: Codable, Sendable {
  public let id: Int64
  public let name: String
}

/// Deterministic token-overlap resolver over the catalog slice — the scoring shape the
/// app uses for catalog suggestions, kept self-contained so the evaluation is
/// reproducible offline. Deterministic order: score descending, then id ascending.
public struct TokenMatchResolver: BarcodeCatalogResolver {
  public let items: [EvalCatalogItem]

  public init(items: [EvalCatalogItem]) {
    self.items = items
  }

  public func candidates(for productName: String?, brands: String?) -> [CatalogCandidate] {
    let query = Self.tokens(in: [productName, brands].compactMap { $0 }.joined(separator: " "))
    guard !query.isEmpty else { return [] }

    var scored: [CatalogCandidate] = []
    for item in items {
      let target = Self.tokens(in: item.name)
      guard !target.isEmpty else { continue }
      let overlap = Double(query.intersection(target).count)
      let smaller = Double(min(query.count, target.count))
      let score = overlap / smaller
      if score >= 0.3 {
        scored.append(CatalogCandidate(id: item.id, name: item.name, score: score))
      }
    }
    return scored.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.id < rhs.id
    }
  }

  public static func tokens(in text: String) -> Set<String> {
    let lowered = text.lowercased()
    return Set(
      lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    ).filter { $0.count > 1 }
  }
}

public enum EvalError: Error, Equatable {
  case badProvenanceDate(String)
}

/// Serves the committed fixture records as barcode lookups, keyed by canonical GTIN-14,
/// with every product pinned to the provenance recorded in `PROVENANCE.json`.
public struct FixtureTransport: BarcodeTransport {
  let byGTIN: [String: BarcodeProduct]

  public init(records: [OFFFixtureRecord], provenance: EvalProvenance) throws {
    guard let retrievedAt = provenance.retrievedAtDate else {
      throw EvalError.badProvenanceDate(provenance.retrievedAt)
    }
    // The search endpoint that produced every fixture page; full per-page URLs and the
    // retrieval timestamp live in PROVENANCE.json.
    let sourceURL = "https://world.openfoodfacts.org/api/v2/search"

    var map: [String: BarcodeProduct] = [:]
    for record in records {
      guard let gtin = try? GTINValidator.validate(record.code) else { continue }
      let off = OpenFoodFactsRecord(
        code: record.code,
        productName: record.productName,
        brands: record.brands,
        quantity: record.quantity,
        servingSize: record.servingSize,
        ingredientsText: record.ingredientsText)
      let pinned = PinnedSource(
        sourceId: "openfoodfacts",
        sourceURL: sourceURL,
        license: provenance.license,
        attribution: provenance.attribution,
        retrievedAt: retrievedAt)
      map[gtin.canonicalGTIN14] = off.product(canonicalGTIN: gtin.canonicalGTIN14, source: pinned)
    }
    self.byGTIN = map
  }

  public func fetch(gtin: ValidatedGTIN) async throws -> BarcodeProduct? {
    byGTIN[gtin.canonicalGTIN14]
  }
}

/// Denominator-bound evaluation counts. Every metric is "of attempted" unless stated
/// otherwise in the report consumer.
public struct EvalCounts: Codable, Sendable, Equatable {
  public var attempted = 0
  public var gtinInvalid = 0
  public var gtinValid = 0
  public var pinnedCacheHits = 0
  public var pinnedCacheStale = 0
  public var pinnedCacheMiss = 0
  /// Records whose quantity yielded grams from explicit mass evidence.
  public var explicitUsableMass = 0
  /// Rejection reason → count (never-grams classes: price, count, serving, volume).
  public var massRejections: [String: Int] = [:]
  public var catalogBound = 0
  public var catalogAmbiguous = 0
  public var catalogUnbound = 0
  /// Bound identity AND explicit usable mass — the drafts ready to commit as measured.
  public var resolvableDrafts = 0
}

/// Drives every fixture record through validate → pinned cache → mass normalization →
/// catalog bind. Deterministic: the clock is pinned to the provenance retrieved-at
/// instant, there is no randomness, and iteration order is the file order.
public func runEvaluation(
  records: [OFFFixtureRecord],
  catalogItems: [EvalCatalogItem],
  provenance: EvalProvenance
) async throws -> EvalCounts {
  guard let now = provenance.retrievedAtDate else {
    throw EvalError.badProvenanceDate(provenance.retrievedAt)
  }
  let transport = try FixtureTransport(records: records, provenance: provenance)
  let cache = PinnedLookupCache(transport: transport, now: { now })
  let resolver = TokenMatchResolver(items: catalogItems)
  var counts = EvalCounts()

  for record in records {
    counts.attempted += 1
    let gtin: ValidatedGTIN
    do {
      gtin = try GTINValidator.validate(record.code)
    } catch {
      counts.gtinInvalid += 1
      continue
    }
    counts.gtinValid += 1

    switch try await cache.lookup(gtin: gtin) {
    case .fresh(let product):
      counts.pinnedCacheHits += 1
      account(product: product, resolver: resolver, into: &counts)
    case .stale(let product):
      counts.pinnedCacheStale += 1
      account(product: product, resolver: resolver, into: &counts)
    case .miss:
      counts.pinnedCacheMiss += 1
    }
  }
  return counts
}

/// Mass and binding outcomes for one cache-hit product.
func account(
  product: BarcodeProduct,
  resolver: BarcodeCatalogResolver,
  into counts: inout EvalCounts
) {
  let mass = PackageMassParser.mass(in: product.quantityText)
  if mass.grams != nil {
    counts.explicitUsableMass += 1
  } else if let rejection = mass.rejection {
    counts.massRejections[rejection.rawValue, default: 0] += 1
  }

  let binding = CatalogBinder.bind(
    resolver.candidates(for: product.productName, brands: product.brands))
  switch binding {
  case .bound:
    counts.catalogBound += 1
  case .ambiguous:
    counts.catalogAmbiguous += 1
  case .unbound:
    counts.catalogUnbound += 1
  }

  if case .bound = binding, mass.grams != nil {
    counts.resolvableDrafts += 1
  }
}
