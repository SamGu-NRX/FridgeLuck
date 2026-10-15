import FLFeatureLogic
import XCTest
@testable import FridgeLuck

/// Table tests for the pure outbox rules: backoff sequence, status classification
/// (community SPEC 8.3).
final class OutboxStateMachineTests: XCTestCase {
  func testBackoffDoublesAndCapsAtOneHour() throws {
    let policy = OutboxRetryPolicy()
    let delays = (1...10).map { policy.delay(afterFailedAttempts: $0) }
    XCTAssertEqual(
      delays,
      [60, 120, 240, 480, 960, 1920, 3600, 3600, 3600, 3600],
      "1 min → 2 → 4 → … capped at 1 h")
  }

  func testNextRetryAddsDelayToNow() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let next = OutboxStateMachine.nextRetry(
      now: now, failedAttempts: 3, policy: OutboxRetryPolicy())
    XCTAssertEqual(next.timeIntervalSince(now), 240, accuracy: 0.001)
  }

  func testOutcomeClassification() {
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: nil), .retryWithBackoff)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 201), .succeeded)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 200), .succeeded)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 409), .conflict)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 429), .retryWithBackoff)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 500), .retryWithBackoff)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 503), .retryWithBackoff)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 422), .abandoned)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 400), .abandoned)
    XCTAssertEqual(OutboxStateMachine.outcome(statusCode: 404), .abandoned)
  }

  func testAuthorVisibleCopyMatchesSpec9_9() {
    XCTAssertEqual(AuthorModerationState.private.displayDetail(), "Private — only you can see this.")
    XCTAssertEqual(AuthorModerationState.published.displayDetail(), "In Explore.")
    XCTAssertEqual(
      AuthorModerationState.flagged.displayDetail(), "In Explore — one tag is being double-checked.")
    XCTAssertEqual(
      AuthorModerationState.inReview.displayDetail(),
      "In review — hidden from Explore until a person checks it.")
    XCTAssertEqual(
      AuthorModerationState.removedByReview.displayDetail(reviewReason: "rights"),
      "Removed by review. Reason: rights. You can edit and share a new version.")
    XCTAssertEqual(
      AuthorModerationState.withdrawn.displayDetail(),
      "Removed from Explore. Your recipe is still yours, here.")
  }

  func testAuthorStateDerivationFromStorageStates() {
    XCTAssertEqual(AuthorModerationState.derive(publicationState: "private"), .private)
    XCTAssertEqual(AuthorModerationState.derive(publicationState: "author_only"), .published)
    XCTAssertEqual(
      AuthorModerationState.derive(publicationState: "published", flaggedTag: "sesame"), .flagged)
    XCTAssertEqual(AuthorModerationState.derive(publicationState: "in_review"), .inReview)
    XCTAssertEqual(AuthorModerationState.derive(publicationState: "rejected"), .removedByReview)
    XCTAssertEqual(AuthorModerationState.derive(publicationState: "withdrawn"), .withdrawn)
    XCTAssertEqual(AuthorModerationState.derive(publicationState: "anything-else"), .private)
  }
}
