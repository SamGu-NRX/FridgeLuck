import FLBarcode
import XCTest

/// Transport stub: canned handler plus a call counter, so tests can see when the cache
/// did and did not reach through to the transport.
private actor StubTransport: BarcodeTransport {
  var calls = 0
  let handler: @Sendable (ValidatedGTIN) async throws -> BarcodeProduct?

  init(handler: @escaping @Sendable (ValidatedGTIN) async throws -> BarcodeProduct?) {
    self.handler = handler
  }

  func fetch(gtin: ValidatedGTIN) async throws -> BarcodeProduct? {
    calls += 1
    return try await handler(gtin)
  }
}

/// Source-pinned cache: hits carry pinned provenance, stale responses surface as stale,
/// and the cache sits in front of the transport.
final class PinnedCacheTests: XCTestCase {
  private static let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

  private func makeProduct(
    code: String,
    quantity: String? = "500 g",
    retrievedAt: Date
  ) -> BarcodeProduct {
    BarcodeProduct(
      gtin: code,
      productName: "Greek yogurt",
      brands: "A brand",
      quantityText: quantity,
      servingText: nil,
      ingredientsText: nil,
      source: PinnedSource(
        sourceId: "openfoodfacts",
        sourceURL: "https://world.openfoodfacts.org/api/v2/product/\(code).json",
        license: "ODbL-1.0",
        attribution: "Contains Open Food Facts data.",
        retrievedAt: retrievedAt
      )
    )
  }

  /// The cache answers repeat lookups itself: one transport call for two lookups.
  func testCacheSitsInFrontOfTransport() async throws {
    let product = makeProduct(code: "00036000291452", retrievedAt: Self.fixedNow)
    let transport = StubTransport(handler: { _ in product })
    let cache = PinnedLookupCache(transport: transport, now: { Self.fixedNow })

    let first = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))
    let second = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))

    guard case .fresh(let hit) = first else { return XCTFail("expected fresh, got \(first)") }
    XCTAssertEqual(hit, product)
    guard case .fresh(let cached) = second else {
      return XCTFail("expected fresh, got \(second)")
    }
    XCTAssertEqual(cached, product)
    let calls = await transport.calls
    XCTAssertEqual(calls, 1)
  }

  /// Cached data past the freshness window comes back .stale — surfaced, never
  /// relabeled as fresh — and the record itself is still delivered.
  func testStaleResponseSurfacedAsStale() async throws {
    let clock = Clock(Self.fixedNow)
    let product = makeProduct(
      code: "00036000291452",
      retrievedAt: clock.current
    )
    let transport = StubTransport(handler: { _ in product })
    let cache = PinnedLookupCache(transport: transport, now: { clock.current })

    // First lookup fills the cache straight from the transport → fresh.
    let first = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))
    guard case .fresh = first else { return XCTFail("expected fresh fill, got \(first)") }

    // Later, past the TTL, the same entry is stale.
    clock.advance(days: 100)
    let outcome = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))
    guard case .stale(let stale) = outcome else {
      return XCTFail("expected stale, got \(outcome)")
    }
    XCTAssertEqual(stale, product)
    XCTAssertEqual(stale.source.retrievedAt, product.source.retrievedAt)
  }

  func testFreshWithinTTL() async throws {
    let product = makeProduct(
      code: "00036000291452",
      retrievedAt: Self.fixedNow.addingTimeInterval(-10 * 24 * 3600)
    )
    let transport = StubTransport(handler: { _ in product })
    let cache = PinnedLookupCache(transport: transport, now: { Self.fixedNow })

    let outcome = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))
    guard case .fresh = outcome else { return XCTFail("expected fresh, got \(outcome)") }
  }

  /// Misses are not cached: an absent product re-tries the transport next time.
  func testMissIsNotCached() async throws {
    let transport = StubTransport(handler: { _ in nil })
    let cache = PinnedLookupCache(transport: transport, now: { Self.fixedNow })

    let first = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))
    let second = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))
    XCTAssertEqual(first, .miss)
    XCTAssertEqual(second, .miss)
    let calls = await transport.calls
    XCTAssertEqual(calls, 2)
  }

  /// Transport failures propagate to the caller — never swallowed into a miss.
  func testTransportErrorPropagates() async {
    let transport = StubTransport(handler: { _ in throw StubError.networkDown })
    let cache = PinnedLookupCache(transport: transport, now: { Self.fixedNow })

    do {
      _ = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))
      XCTFail("expected throw")
    } catch {
      XCTAssertEqual(error as? StubError, .networkDown)
    }
  }

  /// Leading-zero forms of one product share a cache entry (canonical GTIN-14 key).
  func testCanonicalKeyDedupesForms() async throws {
    let product = makeProduct(code: "00036000291452", retrievedAt: Self.fixedNow)
    let transport = StubTransport(handler: { _ in product })
    let cache = PinnedLookupCache(transport: transport, now: { Self.fixedNow })

    _ = try await cache.lookup(gtin: GTINValidator.validate("036000291452"))
    _ = try await cache.lookup(gtin: GTINValidator.validate("00036000291452"))
    _ = try await cache.lookup(gtin: GTINValidator.validate("0036000291452"))

    let calls = await transport.calls
    XCTAssertEqual(calls, 1)
  }

  private enum StubError: Error, Equatable {
    case networkDown
  }

  /// A manually-advanced clock so staleness is simulated without wall time.
  private final class Clock: @unchecked Sendable {
    var current: Date
    init(_ start: Date) { current = start }
    func advance(days: Double) { current = current.addingTimeInterval(days * 86_400) }
  }
}
