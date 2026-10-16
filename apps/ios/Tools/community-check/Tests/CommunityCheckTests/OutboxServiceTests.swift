import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import GRDB
import XCTest
@testable import CommunityCheckKit

/// Scriptable transport: records every request and answers from a queue, or fails like an
/// offline device.
final class MockCommunityTransport: CommunityTransport, @unchecked Sendable {
  struct RecordedCall: Equatable {
    let method: String
    let path: String
    let body: Data?
  }

  private let lock = NSLock()
  private var callsStorage: [RecordedCall] = []
  private var responses: [(status: Int, data: Data)] = []
  private var offline = false

  var calls: [RecordedCall] {
    lock.lock()
    defer { lock.unlock() }
    return callsStorage
  }

  func setOffline(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    offline = value
  }

  func enqueueResponse(status: Int, data: Data) {
    lock.lock()
    defer { lock.unlock() }
    responses.append((status, data))
  }

  /// Locked section runs in a synchronous scope: `NSLock.lock`/`unlock` are unavailable
  /// from asynchronous contexts, so `send` cannot hold the lock directly.
  private func recordCallAndTakeResponse(
    for request: URLRequest
  ) throws -> (status: Int, data: Data) {
    lock.lock()
    defer { lock.unlock() }
    if offline {
      throw URLError(.notConnectedToInternet)
    }
    callsStorage.append(
      RecordedCall(
        method: request.httpMethod ?? "",
        path: request.url?.path ?? "",
        body: request.httpBody))
    return
      responses.isEmpty
      ? (status: 200, data: Data("{}".utf8))
      : responses.removeFirst()
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let response = try recordCallAndTakeResponse(for: request)

    let http = HTTPURLResponse(
      url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
    return (response.data, http)
  }
}

/// The outbox drain loop: offline publishes stay queued; back online, exactly one send per
/// operation with a stable idempotency key; withdrawals stop queued publishes (SPEC 8.3).
final class OutboxServiceTests: XCTestCase {
  private var db: DatabaseQueue!
  private var store: CommunityStore!
  private var transport: MockCommunityTransport!
  private var client: CommunityAPIClient!
  private var service: OutboxService!
  private let start = Date(timeIntervalSince1970: 1_790_000_000)

  override func setUpWithError() throws {
    db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    store = CommunityStore(db: db)
    transport = MockCommunityTransport()
    client = CommunityAPIClient(baseURL: URL(string: "https://community.example/v1")!, transport: transport)
    service = OutboxService(store: store, client: client)
  }

  private func makeRecipeWithQueuedPublish() throws -> (recipeId: Int64, outboxId: Int64, payload: CreatePublicationRequest) {
    let recipeId = try store.createUserRecipe(Self.curryContent())
    let communityId = try XCTUnwrap(store.userRecipe(recipeId: recipeId)).communityRecipeId
    let payload = SharePreviewBuilder.payload(
      communityRecipeId: communityId, revision: 1, content: Self.curryContent(),
      declaration: RecipeRightsDeclaration(ownRights: true, noPersonalData: true),
      operationId: "D1B2F0A4-9C3E-4A7F-8B21-5F6A7B8C9D0E")
    let outboxId = try store.enqueue(
      .publish, payload: JSONEncoder().encode(payload), recipeId: recipeId, operationId: payload.operationId, now: start)
    return (recipeId, outboxId, payload)
  }

  private static func curryContent() -> RecipeRevisionContent {
    RecipeRevisionContent(
      title: "Butter bean curry",
      description: "One-pan, mild, cheap.",
      servings: 2,
      timeMinutes: 35,
      ingredientLines: [IngredientLine(name: "butter beans", quantity: 400, unit: .gram)],
      steps: [RecipeStep(text: "Simmer everything.", timerMinutes: 20)])
  }

  private static func publicationResponse(
    communityId: String, state: PublicationState = .published
  ) -> Data {
    let publication = Publication(
      publicationId: "pub_M3Np8qXw2R",
      recipeRef: RecipeRef(source: .user, id: communityId, revision: 1),
      content: curryContent(),
      authorDisplayName: "Sam",
      allergenTags: [],
      state: state,
      publishedAt: "2026-10-15T18:40:00Z")
    return try! JSONEncoder().encode(publication)
  }

  func testOfflinePublishStaysQueuedAndSendsExactlyOnceWhenBackOnline() async throws {
    let made = try makeRecipeWithQueuedPublish()

    // Offline: the publish stays queued, one backoff attempt is scheduled, nothing sends.
    transport.setOffline(true)
    var result = await service.drain(now: start)
    XCTAssertEqual(result.retried, 1)
    XCTAssertEqual(transport.calls.count, 0)
    XCTAssertEqual(try store.outboxState(id: made.outboxId), .queued)
    XCTAssertEqual(try store.authorModerationState(recipeId: made.recipeId), .private)

    // Back online, past the 1-minute backoff: the queued publish sends exactly once.
    transport.setOffline(false)
    transport.enqueueResponse(status: 201, data: Self.publicationResponse(communityId: made.payload.recipeRef.id))
    let afterBackoff = start.addingTimeInterval(120)
    result = await service.drain(now: afterBackoff)
    XCTAssertEqual(result.sent, 1)
    XCTAssertEqual(transport.calls.count, 1)
    XCTAssertEqual(transport.calls.first?.method, "POST")
    XCTAssertTrue(transport.calls.first?.path.hasSuffix("/publications") ?? false)

    // The row is gone; draining again sends nothing.
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
    result = await service.drain(now: afterBackoff.addingTimeInterval(3600))
    XCTAssertEqual(result.sent, 0)
    XCTAssertEqual(transport.calls.count, 1, "the confirmed publish must not send twice")

    // The server response landed: publication recorded, author sees it in Explore.
    let recipe = try XCTUnwrap(store.userRecipe(recipeId: made.recipeId))
    XCTAssertEqual(recipe.publicationId, "pub_M3Np8qXw2R")
    XCTAssertEqual(try store.authorModerationState(recipeId: made.recipeId), .published)
  }

  func testRetriedSendCarriesTheSameOperationId() async throws {
    let made = try makeRecipeWithQueuedPublish()
    transport.setOffline(true)
    _ = await service.drain(now: start)

    transport.setOffline(false)
    transport.enqueueResponse(status: 201, data: Self.publicationResponse(communityId: made.payload.recipeRef.id))
    _ = await service.drain(now: start.addingTimeInterval(120))

    let body = try XCTUnwrap(transport.calls.first?.body)
    let sent = try JSONDecoder().decode(CreatePublicationRequest.self, from: body)
    XCTAssertEqual(sent.operationId, "D1B2F0A4-9C3E-4A7F-8B21-5F6A7B8C9D0E")
  }

  func testWithdrawnRecipeStopsSending() async throws {
    let made = try makeRecipeWithQueuedPublish()

    // Withdraw while the publish is still queued: the publish is cancelled before it can
    // leave the phone, and no withdraw request is needed (nothing was published yet).
    _ = try store.cancelQueuedPublishes(recipeId: made.recipeId, reason: "withdrawn by author")
    let result = await service.drain(now: start.addingTimeInterval(120))

    XCTAssertEqual(result.sent, 0)
    XCTAssertEqual(transport.calls.count, 0, "a withdrawn recipe must not send")
    XCTAssertEqual(try store.outboxState(id: made.outboxId), .cancelled)
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
  }

  func testWithdrawWithServerPublicationSendsDeleteAndMarksWithdrawn() async throws {
    let recipeId = try store.createUserRecipe(Self.curryContent())
    let communityId = try XCTUnwrap(store.userRecipe(recipeId: recipeId)).communityRecipeId
    let publication = Publication(
      publicationId: "pub_M3Np8qXw2R",
      recipeRef: RecipeRef(source: .user, id: communityId, revision: 1),
      content: Self.curryContent(),
      authorDisplayName: "Sam",
      allergenTags: [],
      state: .published,
      publishedAt: "2026-10-15T18:40:00Z")
    try store.applyPublication(publication, recipeId: recipeId)

    let withdrawPayload = try JSONEncoder().encode(WithdrawPublicationRequest(publicationId: "pub_M3Np8qXw2R"))
    let outboxId = try store.enqueue(.withdraw, payload: withdrawPayload, recipeId: recipeId, now: start)
    transport.enqueueResponse(status: 200, data: Self.publicationResponse(communityId: communityId, state: .withdrawn))

    let result = await service.drain(now: start)

    XCTAssertEqual(result.sent, 1)
    XCTAssertEqual(transport.calls.first?.method, "DELETE")
    XCTAssertTrue(transport.calls.first?.path.hasSuffix("publications/pub_M3Np8qXw2R") ?? false)
    XCTAssertEqual(try store.outboxState(id: outboxId), nil, "row removed on confirmed success")
    XCTAssertEqual(try store.authorModerationState(recipeId: recipeId), .withdrawn)
  }

  func testConflictSurfacesAndNeverAutoResolves() async throws {
    let made = try makeRecipeWithQueuedPublish()
    transport.enqueueResponse(status: 409, data: Data("{\"error\":\"recipe_revised_offline\"}".utf8))

    let result = await service.drain(now: start)

    XCTAssertEqual(result.conflicts, 1)
    XCTAssertEqual(try store.outboxState(id: made.outboxId), .conflict)
    XCTAssertEqual(try store.queuedOutboxCount(), 0)
  }

  func testPermanentClientErrorStopsTheRow() async throws {
    let made = try makeRecipeWithQueuedPublish()
    transport.enqueueResponse(status: 422, data: Data("{}".utf8))

    let result = await service.drain(now: start)

    XCTAssertEqual(result.failed, 1)
    XCTAssertEqual(try store.outboxState(id: made.outboxId), .failed)
    XCTAssertEqual(transport.calls.count, 1)
  }

  func testServerErrorBacksOffBeforeRetrying() async throws {
    let made = try makeRecipeWithQueuedPublish()
    transport.enqueueResponse(status: 503, data: Data("{}".utf8))

    _ = await service.drain(now: start)

    XCTAssertEqual(try store.outboxState(id: made.outboxId), .queued)
    // Not due again until the backoff elapses: draining immediately sends nothing.
    transport.enqueueResponse(status: 201, data: Self.publicationResponse(communityId: made.payload.recipeRef.id))
    let immediate = await service.drain(now: start.addingTimeInterval(10))
    XCTAssertEqual(immediate.sent, 0)
    let afterBackoff = await service.drain(now: start.addingTimeInterval(120))
    XCTAssertEqual(afterBackoff.sent, 1)
  }
}
