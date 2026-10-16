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

  /// The decoded server error body, when the response carried one (error.schema.json).
  public var serverError: CommunityErrorBody? {
    guard case .http(_, let body) = self, !body.isEmpty else { return nil }
    return try? JSONDecoder().decode(CommunityErrorEnvelope.self, from: body).error
  }

  /// The machine-readable server error code, when decodable.
  public var serverErrorCode: CommunityServerErrorCode? {
    serverError.map { CommunityServerErrorCode(code: $0.code) }
  }
}

/// What one 401-refresh attempt concluded (SPEC 6.1): the session family either rotated
/// (retry with the fresh access token), was refused by the server (the original 401 stands
/// and the session is dead), or could not complete at all (network down — callers must keep
/// the tokens and must not treat the request as a dead session).
public enum CommunityRefreshOutcome: Sendable {
  case rotated(accessToken: String, account: CommunityAccount?)
  case rejected
  case unavailable
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
  private let refreshedAuthToken: @Sendable () async -> CommunityRefreshOutcome
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(
    baseURL: URL,
    transport: CommunityTransport = URLSessionCommunityTransport(),
    authToken: @escaping @Sendable () async -> String? = { nil },
    refreshedAuthToken: @escaping @Sendable () async -> CommunityRefreshOutcome = { .rejected }
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

  // MARK: - Session and identity (openapi paths /auth*, /session, /me, /account)

  /// `POST /v1/auth/apple` — authApple. Sent unauthenticated: the identity JWS is the
  /// credential, and no bearer token exists yet (SPEC 6.1).
  public func authApple(_ body: AuthAppleRequest) async throws -> CommunitySession {
    try await sendJSON(
      method: "POST", path: "auth/apple", bodyData: encoder.encode(body), authenticated: false)
  }

  /// `POST /v1/auth/refresh` — refreshSession. Sent unauthenticated: the single-use refresh
  /// token is the credential (SPEC 6.1).
  public func refreshSession(_ body: AuthRefreshRequest) async throws -> CommunitySession {
    try await sendJSON(
      method: "POST", path: "auth/refresh", bodyData: encoder.encode(body), authenticated: false)
  }

  /// `DELETE /v1/session` — revokeSession (204).
  public func revokeSession() async throws {
    try await sendNoContent(method: "DELETE", path: "session")
  }

  /// `DELETE /v1/account` — deleteAccount. 202 starts the resumable deletion plan: the
  /// client confirms twice and then clears local state (SPEC 6.7).
  public func deleteAccount() async throws {
    try await sendNoContent(method: "DELETE", path: "account")
  }

  /// `GET /v1/me` — the account's own view.
  public func me() async throws -> CommunityAccount {
    try await sendJSON(method: "GET", path: "me", bodyData: nil)
  }

  // MARK: - Tables (openapi paths /tables*, /invites*, /blocks*)

  /// `POST /v1/tables` — createTable. 409 `table_full` when the account already owns one
  /// (SPEC 5.1).
  public func createTable(_ body: CommunityCreateTableRequest) async throws -> CommunityTable {
    try await sendJSON(method: "POST", path: "tables", bodyData: encoder.encode(body))
  }

  /// `GET /v1/tables/{tableId}` — getTable.
  public func getTable(_ tableId: String) async throws -> CommunityTable {
    try await sendJSON(method: "GET", path: "tables/\(tableId)", bodyData: nil)
  }

  /// `POST /v1/tables/{tableId}/invites` — createInvite; the only response that carries
  /// `joinCode` (SPEC 5.1).
  public func createInvite(tableId: String) async throws -> CommunityTableInvite {
    try await sendJSON(method: "POST", path: "tables/\(tableId)/invites", bodyData: nil)
  }

  /// `POST /v1/tables/{tableId}/invites/{inviteId}/approve` — approveInvite.
  public func approveInvite(tableId: String, inviteId: String) async throws -> CommunityTableInvite
  {
    try await sendJSON(
      method: "POST", path: "tables/\(tableId)/invites/\(inviteId)/approve", bodyData: nil)
  }

  /// `DELETE /v1/tables/{tableId}/invites/{inviteId}` — revokeInvite (204). This is also how
  /// an owner declines a pending ask.
  public func revokeInvite(tableId: String, inviteId: String) async throws {
    try await sendNoContent(method: "DELETE", path: "tables/\(tableId)/invites/\(inviteId)")
  }

  /// `POST /v1/invites/{code}/join` — joinTable. 202 pending owner approval. A 404 covers
  /// revoked codes, wrong-code tries, and joins between a blocked pair alike — the joiner
  /// is not told which (SPEC 5.1, 6.3).
  public func joinTable(code: String) async throws -> CommunityTableJoinView {
    try await sendJSON(
      method: "POST", path: "invites/\(code.uppercased())/join", bodyData: nil)
  }

  /// `POST /v1/tables/{tableId}/leave` — leaveTable (204). Past cards stay in the table's
  /// history, redacted in every view (SPEC 5.1).
  public func leaveTable(tableId: String) async throws {
    try await sendNoContent(method: "POST", path: "tables/\(tableId)/leave")
  }

  /// `DELETE /v1/tables/{tableId}/members/{accountId}` — removeMember (204), owner only.
  /// The former member loses access; their cards stay redacted in history (SPEC 5.1, 5.4).
  public func removeMember(tableId: String, accountId: String) async throws {
    try await sendNoContent(method: "DELETE", path: "tables/\(tableId)/members/\(accountId)")
  }

  /// `GET /v1/tables/{tableId}/cards` — tableCards, the viewer-filtered card feed (#166).
  public func tableCards(tableId: String) async throws -> [CommunityTableCard] {
    let list: CommunityTableCardList = try await sendJSON(
      method: "GET", path: "tables/\(tableId)/cards", bodyData: nil)
    return list.cards
  }

  /// `POST /v1/tables/{tableId}/cards` — shareCookToTable (201). Idempotent by
  /// `operationId` (SPEC 8.3).
  public func shareCookToTable(
    tableId: String, _ body: CommunityShareCookRequest
  ) async throws -> CommunityTableCard {
    try await sendJSON(
      method: "POST", path: "tables/\(tableId)/cards", bodyData: encoder.encode(body))
  }

  /// `DELETE /v1/tables/{tableId}/cards/{cardId}` — deleteCard (204); the author's own card
  /// only (SPEC 5.2).
  public func deleteCard(tableId: String, cardId: String) async throws {
    try await sendNoContent(method: "DELETE", path: "tables/\(tableId)/cards/\(cardId)")
  }

  /// `PUT /v1/blocks/{accountId}` — addBlock (204).
  public func addBlock(accountId: String) async throws {
    try await sendNoContent(method: "PUT", path: "blocks/\(accountId)")
  }

  /// `DELETE /v1/blocks/{accountId}` — removeBlock (204).
  public func removeBlock(accountId: String) async throws {
    try await sendNoContent(method: "DELETE", path: "blocks/\(accountId)")
  }

  /// `GET /v1/blocks` — listBlocks; private, and the blocked person is never told (SPEC 6.3).
  public func listBlocks() async throws -> [CommunityBlock] {
    let list: CommunityBlockList = try await sendJSON(method: "GET", path: "blocks", bodyData: nil)
    return list.blocks
  }

  // MARK: - Challenges (openapi paths /challenges*)

  /// `GET /v1/challenges` — listChallenges.
  public func challenges() async throws -> [CommunityChallenge] {
    let list: CommunityChallengeList = try await sendJSON(
      method: "GET", path: "challenges", bodyData: nil)
    return list.challenges
  }

  /// `GET /v1/challenges/{challengeId}` — getChallenge.
  public func challenge(id challengeId: String) async throws -> CommunityChallengeDetail {
    try await sendJSON(method: "GET", path: "challenges/\(challengeId)", bodyData: nil)
  }

  /// `POST /v1/challenges/{challengeId}/entries` — createEntry (201). 409
  /// `entries_closed` / `recipe_revised_offline`; 403 `quarantined_rights` (SPEC 4.2, 2.2, 2.3).
  public func createEntry(
    challengeId: String, _ body: CommunityCreateEntryRequest
  ) async throws -> CommunityChallengeEntry {
    try await sendJSON(
      method: "POST", path: "challenges/\(challengeId)/entries", bodyData: encoder.encode(body))
  }

  /// `PUT /v1/challenges/{challengeId}/vote` — castVote (204). Casting again moves the vote.
  /// 409 `vote_too_early`; 403 `account_too_new` (#166) / `blocked` (SPEC 4.2, 4.3, 6.3).
  public func castVote(challengeId: String, _ body: CommunityCastVoteRequest) async throws {
    try await sendNoResponse(
      method: "PUT", path: "challenges/\(challengeId)/vote", bodyData: encoder.encode(body))
  }

  /// `DELETE /v1/challenges/{challengeId}/vote` — removeVote (204).
  public func removeVote(challengeId: String) async throws {
    try await sendNoContent(method: "DELETE", path: "challenges/\(challengeId)/vote")
  }

  /// `POST /v1/reports` — createReport (202). The reported content hides from everyone
  /// pending review (SPEC 6.4).
  public func createReport(_ body: CommunityCreateReportRequest) async throws {
    try await sendNoResponse(method: "POST", path: "reports", bodyData: encoder.encode(body))
  }

  // MARK: - Request plumbing

  private func sendJSON<Response: Decodable>(
    method: String,
    path: String,
    bodyData: Data?,
    authenticated: Bool = true
  ) async throws -> Response {
    let (data, response) = try await perform(
      method: method, path: path, body: bodyData, authenticated: authenticated)
    guard (200...299).contains(response.statusCode) else {
      throw CommunityAPIError.http(status: response.statusCode, body: data)
    }
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw CommunityAPIError.decoding("\(path): \(error)")
    }
  }

  /// Sends a request whose success carries no useful body (202/204). Failure bodies are
  /// kept: typed server errors ride the same envelope on no-content endpoints.
  private func sendNoContent(method: String, path: String, authenticated: Bool = true) async throws
  {
    let (data, response) = try await perform(
      method: method, path: path, body: nil, authenticated: authenticated)
    guard (200...299).contains(response.statusCode) else {
      throw CommunityAPIError.http(status: response.statusCode, body: data)
    }
  }

  /// Sends a request with a body whose success carries no useful body (PUT vote 204,
  /// POST report 202).
  private func sendNoResponse(
    method: String, path: String, bodyData: Data, authenticated: Bool = true
  ) async throws {
    let (data, response) = try await perform(
      method: method, path: path, body: bodyData, authenticated: authenticated)
    guard (200...299).contains(response.statusCode) else {
      throw CommunityAPIError.http(status: response.statusCode, body: data)
    }
  }

  private func perform(
    method: String,
    path: String,
    body: Data?,
    authenticated: Bool = true
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if authenticated, let token = await authToken() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await transport.send(request)

    // Transparent refresh: one retry on 401 (SPEC 8.5). A refresh the server refused ends
    // the session family, so the original 401 propagates; a refresh that could not complete
    // (network down) must NOT read as a dead session — surface a transport-level failure
    // instead so callers keep their tokens and retry later.
    if response.statusCode == 401, authenticated {
      switch await refreshedAuthToken() {
      case .rotated(let fresh, _):
        var retried = request
        retried.httpBody = body
        retried.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
        return try await transport.send(retried)
      case .unavailable:
        throw CommunityAPIError.invalidResponse
      case .rejected:
        break
      }
    }
    return (data, response)
  }
}
