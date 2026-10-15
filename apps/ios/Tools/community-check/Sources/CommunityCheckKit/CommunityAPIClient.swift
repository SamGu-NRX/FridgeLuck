import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The HTTP seam of `CommunityAPIClient`, so decoding and retry behaviour are testable
/// without a network (SPEC 8.5).
public protocol CommunityTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport over a `URLSession`.
public struct URLSessionCommunityTransport: CommunityTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CommunityAPIError.invalidResponse
    }
    return (data, http)
  }
}

public enum CommunityAPIError: Error, Sendable, Equatable {
  case http(status: Int, body: Data)
  case invalidResponse
  case decoding(String)

  public var statusCode: Int? {
    if case .http(let status, _) = self { return status }
    return nil
  }
}

/// Thin typed client for the community contract (`docs/spec/community/contracts/openapi.yaml`,
/// SPEC 8.5): one method per operation the app uses, bearer auth, and transparent token
/// refresh with one retry on 401. Response decoding is tested against `contracts/examples/`.
///
/// Paths are appended to `baseURL`, which must already include the version prefix
/// (e.g. `https://community.example/v1`).
public final class CommunityAPIClient: Sendable {
  private let baseURL: URL
  private let transport: CommunityTransport
  private let authToken: @Sendable () async -> String?
  private let refreshedAuthToken: @Sendable () async -> String?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(
    baseURL: URL,
    transport: CommunityTransport = URLSessionCommunityTransport(),
    authToken: @escaping @Sendable () async -> String? = { nil },
    refreshedAuthToken: @escaping @Sendable () async -> String? = { nil }
  ) {
    self.baseURL = baseURL
    self.transport = transport
    self.authToken = authToken
    self.refreshedAuthToken = refreshedAuthToken
  }

  // MARK: - Publications (openapi paths /publications*)

  /// `POST /v1/publications` — createPublication. Idempotent by `operationId`: replays of the
  /// same request return the first response, not a duplicate publication (SPEC 8.3).
  public func createPublication(_ body: CreatePublicationRequest) async throws -> Publication {
    try await sendJSON(method: "POST", path: "publications", bodyData: encoder.encode(body))
  }

  /// `DELETE /v1/publications/{publicationId}` — withdrawPublication.
  public func withdrawPublication(_ publicationId: String) async throws -> Publication {
    try await sendJSON(method: "DELETE", path: "publications/\(publicationId)", bodyData: nil)
  }

  /// `GET /v1/publications/mine` — the account's publications with moderation states.
  public func myPublications() async throws -> [Publication] {
    let list: PublicationList = try await sendJSON(
      method: "GET", path: "publications/mine", bodyData: nil)
    return list.publications
  }

  /// `GET /v1/publications/{publicationId}` — getPublication.
  public func getPublication(_ publicationId: String) async throws -> Publication {
    try await sendJSON(method: "GET", path: "publications/\(publicationId)", bodyData: nil)
  }

  // MARK: - Request plumbing

  private func sendJSON<Response: Decodable>(
    method: String,
    path: String,
    bodyData: Data?
  ) async throws -> Response {
    let (data, response) = try await perform(method: method, path: path, body: bodyData)
    guard (200...299).contains(response.statusCode) else {
      throw CommunityAPIError.http(status: response.statusCode, body: data)
    }
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw CommunityAPIError.decoding("\(path): \(error)")
    }
  }

  private func perform(
    method: String,
    path: String,
    body: Data?
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token = await authToken() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await transport.send(request)

    // Transparent refresh: one retry on 401 (SPEC 8.5).
    if response.statusCode == 401, let fresh = await refreshedAuthToken() {
      var retried = request
      retried.httpBody = body
      retried.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
      return try await transport.send(retried)
    }
    return (data, response)
  }
}
