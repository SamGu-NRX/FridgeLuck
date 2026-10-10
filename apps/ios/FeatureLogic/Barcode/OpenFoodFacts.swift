import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A product record from the Open Food Facts API (v2 field names), kept decodable from
/// both the live API and the frozen offline fixture (JSONL of the same fields).
public struct OpenFoodFactsRecord: Sendable, Equatable, Decodable {
  public let code: String?
  public let productName: String?
  public let brands: String?
  public let quantity: String?
  public let servingSize: String?
  public let ingredientsText: String?

  public enum CodingKeys: String, CodingKey {
    case code
    case productName = "product_name"
    case brands
    case quantity
    case servingSize = "serving_size"
    case ingredientsText = "ingredients_text"
  }

  public init(
    code: String?, productName: String?, brands: String?, quantity: String?,
    servingSize: String?, ingredientsText: String?
  ) {
    self.code = code
    self.productName = productName
    self.brands = brands
    self.quantity = quantity
    self.servingSize = servingSize
    self.ingredientsText = ingredientsText
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decodeIfPresent(String.self, forKey: .code)
    productName = try container.decodeIfPresent(String.self, forKey: .productName)
    brands = try container.decodeIfPresent(String.self, forKey: .brands)
    quantity = try container.decodeIfPresent(String.self, forKey: .quantity)
    servingSize = try container.decodeIfPresent(String.self, forKey: .servingSize)
    ingredientsText = try container.decodeIfPresent(String.self, forKey: .ingredientsText)
  }

  /// The license OFF data carries and the attribution its use requires.
  public static let license = "ODbL-1.0"
  public static let attribution =
    "Contains Open Food Facts data (openfoodfacts.org, Open Food Facts community), licensed under ODbL-1.0."

  /// Maps the record onto a pinned product. The caller supplies the canonical GTIN-14
  /// (the record's raw `code` may be an unvalidated or unusual form).
  public func product(canonicalGTIN: String, source: PinnedSource) -> BarcodeProduct {
    BarcodeProduct(
      gtin: canonicalGTIN,
      productName: productName,
      brands: brands,
      quantityText: quantity,
      servingText: servingSize,
      ingredientsText: ingredientsText,
      source: source
    )
  }
}

/// Live Open Food Facts transport. Network access is OPTIONAL for this feature: the app
/// gates this type behind a feature flag, and no test depends on it.
///
/// Behavior (documented for the flag's owner):
/// - One GET per lookup at `{base}/api/v2/product/{gtin}.json` with only the fields the
///   intake needs; no retries, no batching — misses are returned as `nil`, not cached.
/// - Requests carry an identifying User-Agent; OFF asks clients to identify themselves.
/// - Responses pin provenance (source URL, ODbL license, retrieved now) at fetch time.
/// - HTTP errors and decode failures throw — they are never swallowed into a miss.
public struct OpenFoodFactsTransport: BarcodeTransport {
  public static let defaultBaseURL = "https://world.openfoodfacts.org"

  public let session: URLSession
  public let baseURL: String
  /// Identifying User-Agent OFF requests from API clients.
  public let userAgent: String
  private let now: @Sendable () -> Date

  public init(
    session: URLSession = .shared,
    baseURL: String = OpenFoodFactsTransport.defaultBaseURL,
    userAgent: String,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.session = session
    self.baseURL = baseURL
    self.userAgent = userAgent
    self.now = now
  }

  public func fetch(gtin: ValidatedGTIN) async throws -> BarcodeProduct? {
    let fields = "product_name,brands,quantity,serving_size,ingredients_text"
    guard
      let url = URL(
        string: "\(baseURL)/api/v2/product/\(gtin.canonicalGTIN14).json?fields=\(fields)")
    else { return nil }

    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

    let payload = try JSONDecoder().decode(ProductPayload.self, from: data)
    guard payload.status == 1, let record = payload.product else { return nil }

    let source = PinnedSource(
      sourceId: "openfoodfacts",
      sourceURL: url.absoluteString,
      license: OpenFoodFactsRecord.license,
      attribution: OpenFoodFactsRecord.attribution,
      retrievedAt: now()
    )
    return record.product(canonicalGTIN: gtin.canonicalGTIN14, source: source)
  }

  struct ProductPayload: Decodable {
    let status: Int?
    let product: OpenFoodFactsRecord?
  }
}
