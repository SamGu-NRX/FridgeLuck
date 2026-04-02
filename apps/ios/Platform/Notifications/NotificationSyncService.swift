import Foundation

protocol NotificationSyncServing: Sendable {
  func fetchFreshnessOpportunities(
    rule: NotificationRule,
    inventoryItems: [InventoryActiveItem]
  ) async throws -> [NotificationOpportunity]?
}

final class NotificationSyncService: @unchecked Sendable, NotificationSyncServing {
  struct Config: Sendable {
    let backendBaseURL: URL?

    static func load() -> Config {
      let env = ProcessInfo.processInfo.environment["GEMINI_BACKEND_BASE_URL"]
      let plist = Bundle.main.object(forInfoDictionaryKey: "GEMINI_BACKEND_BASE_URL") as? String
      let resolved = [env, plist]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        .flatMap(URL.init(string:))
      return Config(backendBaseURL: resolved)
    }
  }

  private enum DefaultsKeys {
    static let installationId = "notificationSync_installationId"
  }

  private let config: Config
  private let session: URLSession
  private let defaults: UserDefaults
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    config: Config = .load(),
    session: URLSession = .shared,
    defaults: UserDefaults = .standard
  ) {
    self.config = config
    self.session = session
    self.defaults = defaults

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func fetchFreshnessOpportunities(
    rule: NotificationRule,
    inventoryItems: [InventoryActiveItem]
  ) async throws -> [NotificationOpportunity]? {
    guard let baseURL = config.backendBaseURL else { return nil }

    let requestBody = NotificationSyncRequest(
      installationId: installationId(),
      timezone: TimeZone.current.identifier,
      locale: Locale.current.identifier,
      generatedAt: Date(),
      rules: [
        NotificationSyncRule(
          kind: .useSoonAlerts,
          enabled: rule.enabled,
          hour: rule.hour,
          minute: rule.minute,
          pushToken: nil
        )
      ],
      inventorySnapshot: inventoryItems.map {
        NotificationSyncInventoryItem(
          ingredientId: $0.ingredientId,
          ingredientName: $0.ingredientName,
          quantityGrams: $0.totalRemainingGrams,
          expiresAt: $0.earliestExpiresAt,
          confidenceScore: $0.averageConfidenceScore
        )
      }
    )

    let endpoint = baseURL.appendingPathComponent("v1/notifications/plan")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try encoder.encode(requestBody)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode
    else {
      return nil
    }

    let payload = try decoder.decode(NotificationSyncResponse.self, from: data)
    let payloadEncoder = JSONEncoder()
    payloadEncoder.dateEncodingStrategy = .iso8601

    return try payload.opportunities.map { item in
      NotificationOpportunity(
        id: item.id,
        kind: item.kind,
        title: item.title,
        body: item.body,
        scheduledAt: item.scheduledAt,
        payloadJSON: String(
          data: try payloadEncoder.encode(item.payload),
          encoding: .utf8
        ) ?? "{}",
        source: .backend,
        status: .scheduled,
        updatedAt: payload.generatedAt
      )
    }
  }

  private func installationId() -> String {
    if let existing = defaults.string(forKey: DefaultsKeys.installationId), !existing.isEmpty {
      return existing
    }

    let created = UUID().uuidString.lowercased()
    defaults.set(created, forKey: DefaultsKeys.installationId)
    return created
  }
}
