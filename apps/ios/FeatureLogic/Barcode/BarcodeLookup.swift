import Foundation

/// The pinned provenance every cached product response carries: where it came from, under
/// what license, and when it was retrieved. A cached response without this pin is not
/// usable — staleness can only be judged against a retrieval date.
public struct PinnedSource: Sendable, Equatable, Hashable, Codable {
  /// Stable identifier for the data source, e.g. "openfoodfacts".
  public let sourceId: String
  /// The exact URL the record was retrieved from.
  public let sourceURL: String
  /// License of the retrieved data, e.g. "ODbL-1.0".
  public let license: String
  /// Attribution the license requires when data is shown or derived.
  public let attribution: String
  /// When the record was retrieved from the source.
  public let retrievedAt: Date

  public init(
    sourceId: String, sourceURL: String, license: String, attribution: String, retrievedAt: Date
  ) {
    self.sourceId = sourceId
    self.sourceURL = sourceURL
    self.license = license
    self.attribution = attribution
    self.retrievedAt = retrievedAt
  }
}

/// One barcode product record. Free-text quantity fields are kept as text — grams are
/// derived only through `PackageMassParser`, never here.
public struct BarcodeProduct: Sendable, Equatable, Codable {
  /// Canonical zero-padded GTIN-14.
  public let gtin: String
  public let productName: String?
  public let brands: String?
  public let quantityText: String?
  public let servingText: String?
  public let ingredientsText: String?
  public let source: PinnedSource

  public init(
    gtin: String, productName: String?, brands: String?, quantityText: String?,
    servingText: String?, ingredientsText: String?, source: PinnedSource
  ) {
    self.gtin = gtin
    self.productName = productName
    self.brands = brands
    self.quantityText = quantityText
    self.servingText = servingText
    self.ingredientsText = ingredientsText
    self.source = source
  }
}

/// What a lookup produced. Stale is a distinct outcome: cached data past its freshness
/// window is surfaced as stale so callers never silently use old data as fresh.
public enum BarcodeLookupOutcome: Sendable, Equatable {
  case fresh(BarcodeProduct)
  case stale(BarcodeProduct)
  /// Nothing cached and the transport found nothing.
  case miss
}

/// The seam behind the cache: wherever product data physically comes from (live API,
/// bundled fixture, none). Transport failures propagate to the caller — they are never
/// swallowed into a miss.
public protocol BarcodeTransport: Sendable {
  func fetch(gtin: ValidatedGTIN) async throws -> BarcodeProduct?
}

/// The lookup surface consumers (intake coordinator, evaluation runner) use.
public protocol BarcodeProductLookup: Sendable {
  func lookup(gtin: ValidatedGTIN) async throws -> BarcodeLookupOutcome
}

/// In-memory product cache sitting in front of a transport.
///
/// Freshness: a hit within `freshnessTTL` of the pinned `retrievedAt` is `.fresh`; past
/// it, the same record comes back `.stale` — surfaced, never relabeled as fresh. A stale
/// hit does not re-fetch (offline-first: refresh is a later, deliberate step). Misses are
/// not cached, so a later transport can be swapped in without stale negative results.
public actor PinnedLookupCache: BarcodeProductLookup {
  public let freshnessTTL: TimeInterval
  private let transport: BarcodeTransport
  private let now: @Sendable () -> Date
  private var entries: [String: BarcodeProduct] = [:]

  public init(
    transport: BarcodeTransport,
    freshnessTTL: TimeInterval = 90 * 24 * 3600,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.freshnessTTL = freshnessTTL
    self.now = now
  }

  public func lookup(gtin: ValidatedGTIN) async throws -> BarcodeLookupOutcome {
    let key = gtin.canonicalGTIN14
    if let product = entries[key] {
      let age = now().timeIntervalSince(product.source.retrievedAt)
      return age <= freshnessTTL ? .fresh(product) : .stale(product)
    }

    guard let fetched = try await transport.fetch(gtin: gtin) else { return .miss }
    entries[key] = fetched
    return .fresh(fetched)
  }
}

/// A transport that always misses: the offline default so intake works with no product
/// data source configured. Every GTIN becomes an unbound draft the user completes.
public struct NullBarcodeTransport: BarcodeTransport {
  public init() {}

  public func fetch(gtin: ValidatedGTIN) async throws -> BarcodeProduct? {
    nil
  }
}
