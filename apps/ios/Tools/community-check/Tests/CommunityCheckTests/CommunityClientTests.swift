import GRDB
import XCTest

@testable import CommunityCheckKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A `CommunityTransport` stub: queues canned `(status, body)` responses, records requests.
/// Path and body assertions run against the recorded `URLRequest`s, which are exactly what
/// the client handed the transport (SPEC 8.5 seam).
final class CommunityStubTransport: CommunityTransport, @unchecked Sendable {
  private struct Canned {
    var status: Int
    var body: Data
  }

  private let lock = NSLock()
  private var canned: [Canned]
  private var recorded: [URLRequest] = []
  private let transportFailuresAt: Set<Int>

  init(_ responses: [(Int, Data)], transportFailuresAt: Set<Int> = []) {
    canned = responses.map { Canned(status: $0.0, body: $0.1) }
    self.transportFailuresAt = transportFailuresAt
  }

  /// A raw transport error (network down), not a `CommunityAPIError`: the request never
  /// reached a server, so no status or error body exists (SPEC 8.3 offline semantics).
  struct Unreachable: Error {}

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    // NSLock.lock()/unlock() are unavailable from async contexts on Apple SDKs; use
    // scoped locking (the sync closure is the only place the lock is held).
    try lock.withLock {
      let index = recorded.count
      recorded.append(request)
      if transportFailuresAt.contains(index) {
        throw Unreachable()
      }
      let next = canned.isEmpty ? Canned(status: 500, body: Data()) : canned.removeFirst()
      // Failable on Apple, implicitly-unwrapped on Linux — binding covers both.
      guard
        let response = HTTPURLResponse(
          url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)
      else { fatalError("invalid canned response") }
      return (next.body, response)
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var sentCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recorded.count
  }

  private func at(_ index: Int) -> URLRequest {
    lock.lock()
    defer { lock.unlock() }
    return recorded[index]
  }

  func body(at index: Int) -> Data { at(index).httpBody ?? Data() }

  /// The request path without the base URL's `/v1` prefix.
  func path(at index: Int) -> String {
    (at(index).url?.path ?? "").replacingOccurrences(of: "/v1", with: "")
  }

  func method(at index: Int) -> String? { at(index).httpMethod }
}

/// Client + view-model behaviour over the stub transport and the real GRDB store: sign-in,
/// refresh rotation, Tables states, offline caching, outbox-driven writes, and the challenge
/// surfaces (community SPEC 5, 4, 6, 8.3, 8.4, 9).
final class CommunityClientTests: XCTestCase {
  private var db: DatabaseQueue!
  private var store: CommunityStore!
  private var transport: CommunityStubTransport!
  private var client: CommunityAPIClient!
  private var sessionService: CommunitySessionService!
  private var tokenStore: InMemoryCommunityTokenStore!

  override func setUpWithError() throws {
    db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    store = CommunityStore(db: db)
    rewire([])
  }

  /// Rebinds the transport, client, and session service over fresh canned responses. The
  /// token store is kept so tests can assert what the service wrote. `transportFailuresAt`
  /// names request indices (absolute, sign-in = 0) that fail with a raw transport error.
  private func rewire(_ responses: [(Int, Data)], transportFailuresAt: Set<Int> = []) {
    transport = CommunityStubTransport(responses, transportFailuresAt: transportFailuresAt)
    client = CommunityAPIClient(
      baseURL: URL(string: "https://community.example/v1")!, transport: transport)
    if tokenStore == nil { tokenStore = InMemoryCommunityTokenStore() }
    sessionService = CommunitySessionService(
      baseURL: URL(string: "https://community.example/v1")!, transport: transport,
      tokenStore: tokenStore)
  }

  private func fixture(_ name: String) throws -> Data {
    try CommunityContractFixtures.load(name)
  }

  /// Signs in with the auth fixture so the account is the adult `Sam` (acc_Q8W2Yt0pXa);
  /// `extra` responses queue behind the sign-in for the calls under test.
  @MainActor
  private func signInAdult(
    _ extra: [(Int, Data)] = [], transportFailuresAt: Set<Int> = []
  ) async throws -> SessionViewModel {
    rewire(
      [(200, try fixture("authApple.response"))] + extra,
      transportFailuresAt: transportFailuresAt)
    let session = SessionViewModel(service: sessionService)
    session.appleRequestNonce()
    await session.signIn(identityToken: "token", birthYear: 2001)
    XCTAssertEqual(session.phase, .signedIn)
    XCTAssertEqual(session.account?.accountId, "acc_Q8W2Yt0pXa")
    return session
  }

  /// The same sign-in with `isAdult` flipped, exercising the real wire path for the under-18
  /// branch of the 18+ gate (SPEC 6.2).
  @MainActor
  private func signInUnder18(_ extra: [(Int, Data)] = []) async throws -> SessionViewModel {
    let adult = String(decoding: try fixture("authApple.response"), as: UTF8.self)
    let under18 = adult.replacingOccurrences(of: "\"isAdult\": true", with: "\"isAdult\": false")
    rewire([(200, Data(under18.utf8))] + extra)
    let session = SessionViewModel(service: sessionService)
    session.appleRequestNonce()
    await session.signIn(identityToken: "token", birthYear: 2001)
    XCTAssertEqual(session.account?.isAdult, false)
    return session
  }

  @MainActor
  private func makeTablesVM(session: SessionViewModel) -> TablesViewModel {
    TablesViewModel(client: sessionService.client, store: store, session: session)
  }

  // MARK: - Sign-in and session (SPEC 6.1, 6.2, 6.7)

  @MainActor
  func testSignInSendsTheContractRequestBodyAndStoresTheSession() async throws {
    _ = try await signInAdult()

    XCTAssertEqual(transport.method(at: 0), "POST")
    XCTAssertEqual(transport.path(at: 0), "/auth/apple")
    let sent = try JSONDecoder().decode(AuthAppleRequest.self, from: transport.body(at: 0))
    XCTAssertEqual(sent.identityToken, "token")
    XCTAssertEqual(sent.attest18Plus, CommunityBirthYearAttestation(birthYear: 2001))

    let tokens = try await tokenStore.read()
    XCTAssertEqual(tokens?.accessToken, "fla1.b64payload.b64mac")
    XCTAssertEqual(tokens?.refreshToken, "flr1.b64random")
  }

  /// The Apple request binds SHA-256 of a raw nonce and the sign-in body carries that raw
  /// nonce verbatim (SPEC 3.3): the server hashes the body nonce and refuses the sign-in
  /// when the identity token's `nonce` claim is not its SHA-256.
  @MainActor
  func testSignInBodyCarriesTheRawNonceBehindTheBoundHash() async throws {
    rewire([(200, try fixture("authApple.response"))])
    let session = SessionViewModel(service: sessionService)
    let boundHash = session.appleRequestNonce()
    await session.signIn(identityToken: "token", birthYear: 2001)
    XCTAssertEqual(session.phase, .signedIn)

    let sent = try JSONDecoder().decode(AuthAppleRequest.self, from: transport.body(at: 0))
    // The public nonce-binding seam is the SHA-256 digest (the portable helper itself is
    // internal to FLFeatureLogic and out of scope for a plain import on macOS).
    XCTAssertEqual(CommunityNonce.authorizationNonce(forRaw: sent.nonce), boundHash)
    // The hash binding is real: the body nonce is not itself the bound value.
    XCTAssertNotEqual(sent.nonce, boundHash)
  }

  /// A sign-in attempted without an Apple request built through `appleRequestNonce()`
  /// fails locally — the server would refuse a token minted outside the bound flow anyway.
  @MainActor
  func testSignInWithoutABoundNonceFailsWithoutSending() async throws {
    rewire([(200, try fixture("authApple.response"))])
    let session = SessionViewModel(service: sessionService)
    await session.signIn(identityToken: "token")
    XCTAssertEqual(session.phase, .signedOut)
    XCTAssertEqual(transport.sentCount, 0)
  }

  /// Vector checks for the portable SHA-256 the nonce binding rides on (no CryptoKit on
  /// the Linux mirror, SPEC 8.5), exercised through the public binding seam.
  func testNonceHashVectors() {
    XCTAssertEqual(
      CommunityNonce.authorizationNonce(forRaw: ""),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    XCTAssertEqual(
      CommunityNonce.authorizationNonce(forRaw: "abc"),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(
      CommunityNonce.authorizationNonce(forRaw: String(repeating: "x", count: 200)),
      "aa20c23e3201834050679e1d88941b9a6fed0557c9a705cb2c315e2e63fd486d")
    // The hash of the hash is stable too — the walk relies on 64 hex chars.
    XCTAssertEqual(CommunityNonce.authorizationNonce(forRaw: "abc").count, 64)
  }

  @MainActor
  func testRestoreRotatesOn401AndKeepsTheRotatedToken() async throws {
    _ = try await signInAdult()

    // me() → 401, refresh → rotated fixture, me() retry → account.
    rewire([
      (401, Data()), (200, try fixture("authRefresh.response")),
      (200, try fixture("getMe.response")),
    ])

    let restored = await sessionService.restore()
    XCTAssertEqual(restored?.accountId, "acc_Q8W2Yt0pXa")
    XCTAssertEqual(transport.method(at: 1), "POST")
    XCTAssertEqual(transport.path(at: 1), "/auth/refresh")
    let refresh = try JSONDecoder().decode(AuthRefreshRequest.self, from: transport.body(at: 1))
    XCTAssertEqual(refresh.refreshToken, "flr1.b64random")
    let tokens = try await tokenStore.read()
    XCTAssertEqual(tokens?.refreshToken, "flr1.b64random2")
  }

  @MainActor
  func testSignInFailureSurfacesTheServerMessageAndSignsOut() async throws {
    let message =
      #"{"error":{"code":"invalid_token","message":"That Apple sign-in expired. Try again.","reason":"auth"}}"#
    rewire([(401, Data(message.utf8))])
    let session = SessionViewModel(service: sessionService)
    session.appleRequestNonce()
    await session.signIn(identityToken: "stale")
    XCTAssertEqual(session.phase, .signedOut)
    XCTAssertEqual(session.failure, .signIn("That Apple sign-in expired. Try again."))
  }

  @MainActor
  func testDeleteAccountSignsOutAfterTheServerConfirms() async throws {
    let session = try await signInAdult([(202, Data())])
    await session.deleteAccount()
    XCTAssertEqual(session.phase, .signedOut)
    XCTAssertNil(session.account)
    let tokens = try await tokenStore.read()
    XCTAssertNil(tokens)
  }

  // MARK: - Tables surface (SPEC 5, §9.6, §9.7, 8.4)

  @MainActor
  func testLoadWithoutATableShowsTheEmptyState() async throws {
    let session = try await signInAdult()
    let vm = makeTablesVM(session: session)
    await vm.load()
    XCTAssertEqual(vm.state, .noTable)
  }

  @MainActor
  func testCreateTableStoresTheLinkAndShowsTheAloneState() async throws {
    let session = try await signInAdult([(200, try fixture("createTable.response"))])
    let vm = makeTablesVM(session: session)
    await vm.createTable(named: "Flat 4B")
    XCTAssertEqual(vm.state, .alone(tableName: "Flat 4B"))
    XCTAssertEqual(try store.activeTableId(), "tbl_F6hJk1Mw9Q")
    XCTAssertEqual(transport.path(at: 1), "/tables")
    XCTAssertEqual(transport.method(at: 1), "POST")
    let sent = try JSONDecoder().decode(
      CommunityCreateTableRequest.self, from: transport.body(at: 1))
    XCTAssertEqual(sent.name, "Flat 4B")
  }

  @MainActor
  func testJoinShowsThePendingAskAndRemembersTheTable() async throws {
    let session = try await signInAdult([(202, try fixture("joinTable.response"))])
    let vm = makeTablesVM(session: session)
    await vm.join(withCode: "M4KPXQ")
    XCTAssertEqual(vm.state, .askingToJoin(tableName: "Flat 4B"))
    XCTAssertEqual(try store.activeTableId(), "tbl_F6hJk1Mw9Q")
    // The code is the credential: POST /invites/{code}/join with no body (SPEC 5.1).
    XCTAssertEqual(transport.path(at: 1), "/invites/M4KPXQ/join")
    XCTAssertEqual(transport.method(at: 1), "POST")
  }

  @MainActor
  func testOfflineLoadRendersTheCachedFeedWithItsTimestamp() async throws {
    let session = try await signInAdult()
    let table = try JSONDecoder().decode(CommunityTable.self, from: fixture("createTable.response"))
    let card = try JSONDecoder().decode(
      CommunityTableCard.self, from: fixture("shareCookToTable.response"))
    let fetchedAt = Date(timeIntervalSince1970: 1_792_276_812)  // 2026-10-15T18:40:12Z
    try store.cacheTable(table: table, cards: [card], tableId: table.tableId, now: fetchedAt)

    rewire([(503, Data())])  // getTable fails
    let vm = makeTablesVM(session: session)
    await vm.load()
    guard case .offline(let tableName, let cards, let asOf) = vm.state else {
      return XCTFail("expected offline state, got \(vm.state)")
    }
    XCTAssertEqual(tableName, "Flat 4B")
    XCTAssertEqual(cards.map(\.cardId), ["crd_J8kLm2Nx0R"])
    XCTAssertEqual(asOf.timeIntervalSince1970, fetchedAt.timeIntervalSince1970, accuracy: 1)
  }

  /// The share write rides the outbox with a dedupeable operationId, then a fresh fetch
  /// renders the feed (SPEC 5.2, 8.3).
  @MainActor
  func testAdultShareSendsThroughTheOutboxAndRefreshesTheFeed() async throws {
    let cardJSON = String(decoding: try fixture("shareCookToTable.response"), as: UTF8.self)
    let cardsBody = "{\"cards\":[\(cardJSON)]}"
    let session = try await signInAdult([
      (200, try fixture("getTable.response")),
      (200, Data(cardsBody.utf8)),
      (200, try fixture("listBlocks.response")),
      (201, try fixture("shareCookToTable.response")),
      (200, try fixture("getTable.response")),
      (200, Data(cardsBody.utf8)),
      (200, try fixture("listBlocks.response")),
    ])
    try store.setActiveTable(tableId: "tbl_F6hJk1Mw9Q")
    let vm = makeTablesVM(session: session)
    await vm.load()
    let cook = CommunitySharedCook(
      recipeRef: RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3),
      dishName: "Butter bean curry", servings: 2,
      swaps: [CommunityCookSwap(fromName: "curry powder", toName: "cumin + paprika")],
      rating: 5, day: "2026-10-14", authorDisplayName: "Sam")
    await vm.share(cook)

    // Request 4 is the share: the outbox row's POST (sign-in, load's 3 reads precede it).
    XCTAssertEqual(transport.method(at: 4), "POST")
    XCTAssertEqual(transport.path(at: 4), "/tables/tbl_F6hJk1Mw9Q/cards")
    let sent = try JSONDecoder().decode(CommunityShareCookRequest.self, from: transport.body(at: 4))
    XCTAssertEqual(sent.cook.dishName, "Butter bean curry")
    XCTAssertFalse(sent.operationId.isEmpty, "the outbox row carries an idempotency key")
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
    XCTAssertEqual(vm.queuedWrites, 0)
    XCTAssertEqual(vm.state.cardsCount(), 1)
    XCTAssertNil(vm.failure)
  }

  @MainActor
  func testNonAdultShareIsRefusedLocallyAndNeverEnqueued() async throws {
    let session = try await signInUnder18()
    try store.setActiveTable(tableId: "tbl_F6hJk1Mw9Q")
    let vm = makeTablesVM(session: session)
    let cook = CommunitySharedCook(
      recipeRef: RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3),
      dishName: "Butter bean curry", servings: 2, day: "2026-10-14")
    await vm.share(cook)
    XCTAssertEqual(vm.failure, .notAdult)
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
    XCTAssertEqual(transport.sentCount, 1, "only the sign-in fired — the gate stops the write")
  }

  @MainActor
  func testTableFullFailureMapsToTheMockCopy() async throws {
    let body =
      #"{"error":{"code":"table_full","message":"Tables are 2-8 people. Someone has to leave first.","reason":"capacity"}}"#
    let session = try await signInAdult([(409, Data(body.utf8))])
    let vm = makeTablesVM(session: session)
    await vm.createTable(named: "Flat 4B")
    XCTAssertEqual(vm.failure, .tableFull)
  }

  @MainActor
  func testLeaveClearsTheLinkAndTheLocalFeed() async throws {
    // The fixture viewer is the table's OWNER, and the server refuses an owner's leave with
    // 409 (backend tables/index.ts:402) — recast the viewer as a member so the leave can be
    // accepted, which is the only flow this happy path represents (§9.7).
    let memberTable =
      #"{"tableId":"tbl_F6hJk1Mw9Q","name":"Flat 4B","createdAt":"2026-10-02T19:00:00Z","members":[{"accountId":"acc_T5RbZ7nY2c","displayName":"Maya","role":"owner","joinedAt":"2026-10-02T19:00:00Z"},{"accountId":"acc_Q8W2Yt0pXa","displayName":"Sam","role":"member","joinedAt":"2026-10-03T08:30:00Z"}],"pendingInvites":[]}"#
    let session = try await signInAdult([
      (200, Data(memberTable.utf8)),
      (200, #"{"cards":[]}"#.data(using: .utf8)!),
      (200, try fixture("listBlocks.response")),
      (204, Data()),
    ])
    try store.setActiveTable(tableId: "tbl_F6hJk1Mw9Q")
    try store.cacheTable(
      table: try JSONDecoder().decode(CommunityTable.self, from: Data(memberTable.utf8)),
      cards: [], tableId: "tbl_F6hJk1Mw9Q")

    let vm = makeTablesVM(session: session)
    await vm.load()
    await vm.leave()
    XCTAssertEqual(vm.state, .noTable)
    XCTAssertNil(vm.failure)
    XCTAssertNil(try store.activeTableId())
    XCTAssertNil(try store.cachedTable(tableId: "tbl_F6hJk1Mw9Q"))
    // Leave fires after the load reads (requests 1-3).
    XCTAssertEqual(transport.path(at: 4), "/tables/tbl_F6hJk1Mw9Q/leave")
    XCTAssertEqual(transport.method(at: 4), "POST")
  }

  // MARK: - Review round: leave safety and error bodies (PR #173 findings 2, 4, 5, 6)

  @MainActor
  func testOwnerLeaveDoesNotDestroyTheLocalTable() async throws {
    // The fixture viewer (acc_Q8W2Yt0pXa) is the table's owner; the server refuses an
    // owner's leave with 409 (backend tables/index.ts:402) and the contract has no
    // "list my tables" read — so a sent-then-refused leave would strand the device.
    let session = try await signInAdult([
      (200, try fixture("getTable.response")),
      (200, #"{"cards":[]}"#.data(using: .utf8)!),
      (200, try fixture("listBlocks.response")),
    ])
    let table = try JSONDecoder().decode(CommunityTable.self, from: fixture("getTable.response"))
    try store.setActiveTable(tableId: table.tableId)
    try store.cacheTable(table: table, cards: [], tableId: table.tableId)

    let vm = makeTablesVM(session: session)
    await vm.load()
    await vm.leave()
    XCTAssertEqual(vm.failure, .ownerCannotLeave)
    XCTAssertEqual(
      transport.sentCount, 4,
      "sign-in plus the three load reads (0-indexed); the leave request may not be sent")
    XCTAssertNotNil(try store.activeTableId())
    XCTAssertNotNil(try store.cachedTable(tableId: table.tableId))
    XCTAssertNotEqual(vm.state, .noTable)
  }

  @MainActor
  func testLeaveConflictKeepsTheLocalTable() async throws {
    // A stale role: the cache says member, the server refuses with 409 — the table is
    // still ours, so local state must survive until the row actually leaves as sent.
    let memberTable =
      #"{"tableId":"tbl_F6hJk1Mw9Q","name":"Flat 4B","createdAt":"2026-10-02T19:00:00Z","members":[{"accountId":"acc_T5RbZ7nY2c","displayName":"Maya","role":"owner","joinedAt":"2026-10-02T19:00:00Z"},{"accountId":"acc_Q8W2Yt0pXa","displayName":"Sam","role":"member","joinedAt":"2026-10-03T08:30:00Z"}],"pendingInvites":[]}"#
    let conflict =
      #"{"error":{"code":"conflict","message":"the owner cannot leave; delete the table instead","reason":"role"}}"#
    let session = try await signInAdult([
      (200, Data(memberTable.utf8)),
      (200, #"{"cards":[]}"#.data(using: .utf8)!),
      (200, try fixture("listBlocks.response")),
      (409, Data(conflict.utf8)),
    ])
    try store.setActiveTable(tableId: "tbl_F6hJk1Mw9Q")
    try store.cacheTable(
      table: try JSONDecoder().decode(CommunityTable.self, from: Data(memberTable.utf8)),
      cards: [], tableId: "tbl_F6hJk1Mw9Q")

    let vm = makeTablesVM(session: session)
    await vm.load()
    await vm.leave()
    XCTAssertEqual(vm.failure, .ownerCannotLeave)
    XCTAssertNotEqual(vm.state, .noTable)
    XCTAssertNotNil(try store.activeTableId())
    XCTAssertNotNil(try store.cachedTable(tableId: "tbl_F6hJk1Mw9Q"))
  }

  @MainActor
  func testPendingJoinSurvivesRelaunchAsAskingToJoin() async throws {
    // A 202 join is linked but pending; the server 404s the table read until the owner
    // approves (requireActiveMembership, backend tables/index.ts). A relaunch over the same
    // store must land back on the asking state, not .failed (§9.6).
    let session = try await signInAdult([
      (202, try fixture("joinTable.response")),
      (404, Data()),
    ])
    let vm = makeTablesVM(session: session)
    await vm.join(withCode: "FL4B2X")
    XCTAssertEqual(vm.state, .askingToJoin(tableName: "Flat 4B"))

    // Relaunch: a fresh view model over the same store; the server still refuses.
    let relaunched = makeTablesVM(session: session)
    await relaunched.load()
    XCTAssertEqual(relaunched.state, .askingToJoin(tableName: "Flat 4B"))
  }

  @MainActor
  func testOfflineJoinSurvivesAsAnOutboxAsk() async throws {
    // The join cannot reach the network: the ask enqueues as an outbox row and the state
    // still reads as asking (SPEC 8.3). A later drain over a live transport lands it.
    let session = try await signInAdult([], transportFailuresAt: [1])
    let vm = makeTablesVM(session: session)
    await vm.join(withCode: "FL4B2X")
    XCTAssertEqual(vm.state, .askingToJoin(tableName: "FL4B2X"))
    XCTAssertEqual(vm.queuedWrites, 1)

    // Back online: the queued joinByCode row links the table when it drains. The drain's
    // `now` is advanced past the transport failure's retry backoff.
    transport = CommunityStubTransport([(202, try fixture("joinTable.response"))])
    let liveClient = CommunityAPIClient(
      baseURL: URL(string: "https://community.example/v1")!, transport: transport)
    await OutboxService(store: store, client: liveClient)
      .drain(now: Date().addingTimeInterval(60 * 60))
    XCTAssertEqual(try store.activeTableId(), "tbl_F6hJk1Mw9Q")
  }

  @MainActor
  func testOfflineCreateTableSurvivesAsAnOutboxRow() async throws {
    // The create cannot reach the network: the intent enqueues as an outbox row and the
    // state still reads as alone (SPEC 8.3). A later drain over a live transport links it.
    let session = try await signInAdult([], transportFailuresAt: [1])
    let vm = makeTablesVM(session: session)
    await vm.createTable(named: "Flat 4B")
    XCTAssertEqual(vm.state, .alone(tableName: "Flat 4B"))
    XCTAssertEqual(vm.queuedWrites, 1)

    // Back online: the queued createTable row creates and links the table when it drains.
    transport = CommunityStubTransport([(200, try fixture("createTable.response"))])
    let liveClient = CommunityAPIClient(
      baseURL: URL(string: "https://community.example/v1")!, transport: transport)
    await OutboxService(store: store, client: liveClient)
      .drain(now: Date().addingTimeInterval(60 * 60))
    let created = try JSONDecoder().decode(
      CommunityTable.self, from: fixture("createTable.response"))
    XCTAssertEqual(try store.activeTableId(), created.tableId)
  }

  @MainActor
  func testRestoreKeepsTokensWhenTheRefreshTransportFails() async throws {
    // Sign in (tokens written), then a restore where me() 401s and the refresh leg
    // cannot reach the network: the tokens must survive for a later retry (SPEC 6.1).
    _ = try await signInAdult([(401, Data())], transportFailuresAt: [2])
    let before = try await tokenStore.read()
    XCTAssertNotNil(before)

    let restored = await sessionService.restore()

    // The refresh could not run (transport), so the 401 says nothing about the session's
    // validity: the tokens and the signed-in account survive for a later retry (SPEC 6.1).
    XCTAssertEqual(restored?.accountId, "acc_Q8W2Yt0pXa")
    let after = try await tokenStore.read()
    XCTAssertNotNil(after, "a transport failure during refresh must keep the tokens")
  }

  @MainActor
  func testTransparentRefreshRefreshesTheAccountSnapshot() async throws {
    // Sign in with the 24 h vote gate still up; the refresh response carries a fresh
    // account (identity/index.ts:120-126) whose lifted gate must reach the snapshot.
    var auth =
      try JSONSerialization.jsonObject(with: fixture("authApple.response")) as! [String: Any]
    var account = auth["account"] as! [String: Any]
    account["canVoteAt"] = "2026-10-16T00:00:00Z"
    auth["account"] = account
    let gatedAuth = try JSONSerialization.data(withJSONObject: auth)
    rewire([
      (200, gatedAuth),
      (401, Data()),  // me() — access token expired
      (200, try fixture("authRefresh.response")),  // fresh account, canVoteAt null
      (200, try fixture("getMe.response")),
    ])
    let session = SessionViewModel(service: sessionService)
    session.appleRequestNonce()
    await session.signIn(identityToken: "token", birthYear: 2001)
    XCTAssertEqual(sessionService.account?.canVoteAt, "2026-10-16T00:00:00Z")

    _ = try? await sessionService.client.me()  // transparent 401 refresh path

    XCTAssertNil(
      sessionService.account?.canVoteAt,
      "the refresh response's fresh account must update the snapshot")
  }

  @MainActor
  func testNoContentEndpointsDecodeServerErrorBodies() async throws {
    // leaveTable rides sendNoContent; the typed error machinery must still see the body.
    let body =
      #"{"error":{"code":"conflict","message":"the owner cannot leave; delete the table instead","reason":"role"}}"#
    let session = try await signInAdult([(409, Data(body.utf8))])
    do {
      try await sessionService.client.leaveTable(tableId: "tbl_F6hJk1Mw9Q")
      XCTFail("expected the 409 to throw")
    } catch let error as CommunityAPIError {
      XCTAssertEqual(error.serverError?.message, "the owner cannot leave; delete the table instead")
    }
  }

  @MainActor
  func testBlockRidesTheOutboxAndRefreshesTheBlockList() async throws {
    let session = try await signInAdult([
      (200, try fixture("getTable.response")),
      (200, #"{"cards":[]}"#.data(using: .utf8)!),
      (200, try fixture("listBlocks.response")),
      (204, Data()),  // PUT blocks/{id}
      (200, try fixture("listBlocks.response")),
      (200, try fixture("getTable.response")),
      (200, #"{"cards":[]}"#.data(using: .utf8)!),
      (200, try fixture("listBlocks.response")),
    ])
    try store.setActiveTable(tableId: "tbl_F6hJk1Mw9Q")
    let vm = makeTablesVM(session: session)
    await vm.load()
    await vm.block("acc_X9mQw3Vb1N")
    // Request 4 is the block: the outbox row's PUT (sign-in, load's 3 reads precede it).
    XCTAssertEqual(transport.method(at: 4), "PUT")
    XCTAssertEqual(transport.path(at: 4), "/blocks/acc_X9mQw3Vb1N")
    XCTAssertTrue(vm.isBlocked("acc_X9mQw3Vb1N"))
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
  }

  // MARK: - Challenge surfaces (SPEC 4, §9.5, 4.3)

  @MainActor
  func testChallengeDetailHidesTalliesWhileVotingIsOpen() async throws {
    let session = try await signInAdult([(200, try fixture("getChallenge.response"))])
    let vm = ChallengeDetailViewModel(
      client: sessionService.client, session: session, challengeId: "chl_B4t8VvQ7Lk")
    await vm.load()
    XCTAssertNil(vm.failure)
    XCTAssertEqual(vm.challenge?.status, .voting)
    XCTAssertFalse(vm.talliesVisible, "no live tallies (SPEC 4.3)")
    XCTAssertFalse(vm.canEnter)
    XCTAssertTrue(vm.votingOpen)
    XCTAssertEqual(vm.myEntryId, "ent_K2mNp4Rs8T")
    XCTAssertNil(vm.myVoteEntryId)
    let entries = vm.entries()
    XCTAssertEqual(entries.count, 2)
    XCTAssertTrue(entries[0].isMine)
    XCTAssertNil(entries[0].visibleVoteCount, "vote counts are nil until voting closes")
    XCTAssertFalse(entries[1].isVoted)
  }

  @MainActor
  func testVoteSendsTheAnonymousEntryIdAndReloads() async throws {
    let session = try await signInAdult([
      (200, try fixture("getChallenge.response")),
      (204, Data()),
      (200, try fixture("getChallenge.response")),
    ])
    let vm = ChallengeDetailViewModel(
      client: sessionService.client, session: session, challengeId: "chl_B4t8VvQ7Lk")
    await vm.load()
    await vm.vote(entryId: "ent_Y9dHj3Lw5P")
    XCTAssertNil(vm.failure)
    XCTAssertEqual(transport.method(at: 2), "PUT")
    XCTAssertEqual(transport.path(at: 2), "/challenges/chl_B4t8VvQ7Lk/vote")
    let sent = try JSONDecoder().decode(CommunityCastVoteRequest.self, from: transport.body(at: 2))
    XCTAssertEqual(sent.entryId, "ent_Y9dHj3Lw5P")
  }

  @MainActor
  func testAccountTooNewVoteMapsToTheGateCopy() async throws {
    let body =
      #"{"error":{"code":"account_too_new","message":"Your vote counts tomorrow.","reason":"age"}}"#
    let session = try await signInAdult([
      (200, try fixture("getChallenge.response")),
      (403, Data(body.utf8)),
    ])
    let vm = ChallengeDetailViewModel(
      client: sessionService.client, session: session, challengeId: "chl_B4t8VvQ7Lk")
    await vm.load()
    await vm.vote(entryId: "ent_Y9dHj3Lw5P")
    XCTAssertEqual(vm.failure, .accountTooNew)
  }

  @MainActor
  func testEntriesClosedEnterMapsToTheWindowCopy() async throws {
    let body =
      #"{"error":{"code":"entries_closed","message":"Entries are closed.","reason":"window"}}"#
    let session = try await signInAdult([(409, Data(body.utf8))])
    let vm = ChallengeDetailViewModel(
      client: sessionService.client, session: session, challengeId: "chl_B4t8VvQ7Lk")
    await vm.enter(
      recipeRef: RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3),
      note: "Crisped the tortilla in the pan first.")
    XCTAssertEqual(vm.failure, .entriesClosed)
  }

  // MARK: - Outbox end-to-end over the store (SPEC 8.3)

  @MainActor
  func testShareCookOutboxRowSendsMergesIntoCacheAndRemovesItself() async throws {
    rewire([(201, try fixture("shareCookToTable.response"))])
    let request = CommunityShareCookRequest(
      operationId: "f3d4e1b6-9e5f-4c9f-ad43-7b8c9d0e1f2a",
      cook: CommunitySharedCook(
        recipeRef: RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3),
        dishName: "Butter bean curry", servings: 2, day: "2026-10-14"))
    let payload = OutboxService.ShareCookOutboxPayload(tableId: "tbl_F6hJk1Mw9Q", request: request)
    // Seed the cache so the merge path runs.
    let table = try JSONDecoder().decode(CommunityTable.self, from: fixture("getTable.response"))
    try store.cacheTable(table: table, cards: [], tableId: table.tableId)
    _ = try store.enqueue(
      .shareCook, payload: JSONEncoder().encode(payload), recipeId: nil,
      operationId: request.operationId)

    let outbox = OutboxService(store: store, client: client)
    let result = await outbox.drain()
    XCTAssertEqual(result.sent, 1)
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
    let cached = try XCTUnwrap(store.cachedTable(tableId: table.tableId))
    XCTAssertEqual(
      cached.cards.map(\.cardId), ["crd_J8kLm2Nx0R"], "the new card joins the cached feed")
  }

  @MainActor
  func testLeaveTableOutboxRowClearsTheLocalFeedAndLink() async throws {
    try store.setActiveTable(tableId: "tbl_F6hJk1Mw9Q")
    let table = try JSONDecoder().decode(CommunityTable.self, from: fixture("getTable.response"))
    try store.cacheTable(table: table, cards: [], tableId: table.tableId)
    let payload = OutboxService.TableEventOutboxPayload(
      event: .leaveTable, tableId: "tbl_F6hJk1Mw9Q")
    _ = try store.enqueue(
      .tableEvent, payload: JSONEncoder().encode(payload), recipeId: nil, operationId: "op-leave")
    rewire([(204, Data())])

    let outbox = OutboxService(store: store, client: client)
    let result = await outbox.drain()
    XCTAssertEqual(result.sent, 1)
    XCTAssertNil(try store.activeTableId())
    XCTAssertNil(try store.cachedTable(tableId: "tbl_F6hJk1Mw9Q"))
  }

  @MainActor
  func testReportOutboxRowSendsAndClears() async throws {
    let request = CommunityCreateReportRequest(
      targetType: .tableMember, targetId: "acc_X9mQw3Vb1N", reason: .harassment, detail: nil)
    let payload = OutboxService.ReportOutboxPayload(request: request)
    _ = try store.enqueue(
      .report, payload: JSONEncoder().encode(payload), recipeId: nil, operationId: "op-report")
    rewire([(202, Data())])

    let outbox = OutboxService(store: store, client: client)
    let result = await outbox.drain()
    XCTAssertEqual(result.sent, 1)
    XCTAssertEqual(transport.path(at: 0), "/reports")
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
  }

  @MainActor
  func testShareCookConflictStopsTheRowAsAConflict() async throws {
    let body =
      #"{"error":{"code":"share_rejected","message":"This card can't be shared.","reason":"conflict"}}"#
    rewire([(409, Data(body.utf8))])
    let request = CommunityShareCookRequest(
      operationId: "f3d4e1b6-9e5f-4c9f-ad43-7b8c9d0e1f2a",
      cook: CommunitySharedCook(
        recipeRef: RecipeRef(source: .user, id: "ur_7Kq2m", revision: 3),
        dishName: "Butter bean curry", servings: 2, day: "2026-10-14"))
    let payload = OutboxService.ShareCookOutboxPayload(tableId: "tbl_F6hJk1Mw9Q", request: request)
    let rowId = try store.enqueue(
      .shareCook, payload: JSONEncoder().encode(payload), recipeId: nil,
      operationId: request.operationId)

    let outbox = OutboxService(store: store, client: client)
    let result = await outbox.drain()
    XCTAssertEqual(result.conflicts, 1)
    XCTAssertEqual(try store.queuedOutboxCount(), 0, "a conflict leaves the queue")
    XCTAssertEqual(
      try store.outboxState(id: rowId), .conflict, "and is never auto-resolved (SPEC 8.3)")
  }
}

extension TablesViewModel.State {
  /// Card count across the states that carry a feed.
  func cardsCount() -> Int {
    if case .active(_, let cards) = self { return cards.count }
    if case .offline(_, let cards, _) = self { return cards.count }
    return -1
  }
}
