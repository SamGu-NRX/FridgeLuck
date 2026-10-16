import FLFeatureLogic
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Owns sign-in state: exchanging an Apple identity token for a session, storing tokens
/// behind `CommunityTokenStore` (Keychain in the app, in-memory in tests), rotating the
/// single-use refresh token exactly once per 401, sign-out, and account deletion
/// (community SPEC 6.1, 6.7, 8.5).
///
/// Refresh is single-flight: concurrent 401s share one rotation, because the refresh token
/// is single-use — a second rotation with the same token would revoke the whole family and
/// sign the account out (SPEC 6.1). A rejected refresh (replay, expiry) clears the store;
/// a transport failure during refresh keeps the tokens for a later retry.
public final class CommunitySessionService: Sendable {
  private let tokenStore: any CommunityTokenStore
  private let authClient: CommunityAPIClient
  private let gate = RefreshGate()
  private let accountBox = AccountBox()

  /// Every authenticated call goes through this client; its `refreshedAuthToken` closure
  /// routes 401s back into `refreshAccessToken()` on this service.
  public let client: CommunityAPIClient

  private final class Bridge: @unchecked Sendable {
    weak var service: CommunitySessionService?
    func refreshedAccessToken() async -> String? {
      await service?.refreshAccessToken()
    }
  }

  private final class AccountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CommunityAccount?
    var current: CommunityAccount? {
      get {
        lock.lock()
        defer { lock.unlock() }
        return value
      }
      set {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
      }
    }
  }

  public init(
    baseURL: URL,
    transport: CommunityTransport = URLSessionCommunityTransport(),
    tokenStore: any CommunityTokenStore = InMemoryCommunityTokenStore()
  ) {
    self.tokenStore = tokenStore
    let bridge = Bridge()
    // Unauthenticated client for /auth*: no bearer exists yet and refresh retries must not
    // recurse into themselves.
    self.authClient = CommunityAPIClient(baseURL: baseURL, transport: transport)
    self.client = CommunityAPIClient(
      baseURL: baseURL,
      transport: transport,
      authToken: { [tokenStore] in (try? await tokenStore.read())?.accessToken },
      refreshedAuthToken: { [bridge] in await bridge.refreshedAccessToken() })
    self.bridge = bridge
    bridge.service = self
  }

  private let bridge: Bridge

  /// The signed-in account, when known (last sign-in or `restore()`).
  public var account: CommunityAccount? { accountBox.current }

  /// Exchanges the Apple identity JWS for a session and stores it. `birthYear` carries the
  /// first-write-wins 18+ attestation when the user is signing in to share (SPEC 6.2).
  /// `rawNonce` is the raw nonce whose SHA-256 the caller bound into the Apple sign-in
  /// request (SPEC 3.3): the body nonce rides verbatim and the server hashes it to match
  /// the identity token's `nonce` claim — hashing here would break that binding.
  /// Throws on failure; the previous session (if any) is left untouched.
  @discardableResult
  public func signIn(identityToken: String, rawNonce: String, birthYear: Int? = nil) async throws -> CommunityAccount
  {
    let request = AuthAppleRequest(
      identityToken: identityToken,
      nonce: rawNonce,
      attest18Plus: birthYear.map(CommunityBirthYearAttestation.init(birthYear:)))
    let session = try await authClient.authApple(request)
    try await tokenStore.write(
      CommunitySessionTokens(accessToken: session.accessToken, refreshToken: session.refreshToken))
    accountBox.current = session.account
    return session.account
  }

  /// Restores the sign-in from stored tokens (app relaunch): verifies against `GET /me`,
  /// which refreshes once through the client on 401. Keeps the tokens when the network is
  /// merely down; clears them when the session family is dead (401 after a refresh attempt).
  @discardableResult
  public func restore() async -> CommunityAccount? {
    guard let tokens = try? await tokenStore.read(), tokens != nil else { return nil }
    do {
      let account = try await client.me()
      accountBox.current = account
      return account
    } catch let error as CommunityAPIError where error.statusCode == 401 {
      try? await tokenStore.clear()
      accountBox.current = nil
      return nil
    } catch {
      return accountBox.current
    }
  }

  /// Revokes the session server-side and clears local tokens. Best effort on the network
  /// call; local state is cleared either way.
  public func signOut() async {
    _ = try? await client.revokeSession()
    try? await tokenStore.clear()
    accountBox.current = nil
  }

  /// `DELETE /v1/account` starts the resumable deletion plan (202): publications withdrawn,
  /// Table cards removed, account deleted (SPEC 6.7). The UI confirms twice before calling
  /// this; on success the local session is cleared.
  public func deleteAccount() async throws {
    try await client.deleteAccount()
    try? await tokenStore.clear()
    accountBox.current = nil
  }

  /// One refresh-and-retry seam for the API client's 401 path. Returns the fresh access
  /// token, or nil when the session is over. Reuse of an old refresh token revokes the
  /// whole family, so a rejected refresh signs the account out locally (SPEC 6.1).
  func refreshAccessToken() async -> String? {
    await gate.refreshedToken { [tokenStore, authClient] in
      guard let tokens = try? await tokenStore.read() else { return nil }
      do {
        let session = try await authClient.refreshSession(
          AuthRefreshRequest(refreshToken: tokens.refreshToken))
        try? await tokenStore.write(
          CommunitySessionTokens(
            accessToken: session.accessToken, refreshToken: session.refreshToken))
        return session.accessToken
      } catch let error as CommunityAPIError
        where error.statusCode == 401 || error.statusCode == 403
      {
        try? await tokenStore.clear()
        return nil
      } catch {
        // Transport failure: keep the tokens; the next 401 retries the rotation.
        return nil
      }
    }
  }
}

/// Serializes refresh so concurrent 401s share exactly one rotation (the refresh token is
/// single-use; two rotations would revoke the family, SPEC 6.1).
private actor RefreshGate {
  private var inFlight: Task<String?, Never>?

  func refreshedToken(
    _ make: @escaping @Sendable () async -> String?
  ) async -> String? {
    if let inFlight {
      return await inFlight.value
    }
    let task = Task { await make() }
    inFlight = task
    let value = await task.value
    inFlight = nil
    return value
  }
}
