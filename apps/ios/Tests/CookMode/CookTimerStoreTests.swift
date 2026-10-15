import FLFeatureLogic
import XCTest

/// Timer deadlines on an injected clock, across a simulated app kill (LeChef §4.2).
final class CookTimerStoreTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
  private let session = "sess_test"

  // MARK: - Creation

  func testCreateUsesAnAbsoluteDeadline() {
    var store = CookTimerStore()
    let result = store.create(id: "timer_1", sessionID: session, label: "Noodles", durationSeconds: 120, now: t0)

    XCTAssertNotNil(result, "a fresh create succeeds")
    XCTAssertEqual(result?.timer.deadline, t0.addingTimeInterval(120))
    XCTAssertEqual(result?.effects, [.scheduleNotification(id: "timer_1", deadline: t0.addingTimeInterval(120))])
    XCTAssertEqual(result?.timer.remainingSeconds(from: t0), 120)
  }

  func testCreateSeveralTimersAtOnce() {
    var store = CookTimerStore()
    _ = store.create(id: "a", sessionID: session, label: "Noodles", durationSeconds: 120, now: t0)
    _ = store.create(id: "b", sessionID: session, label: "Eggs", durationSeconds: 300, now: t0.addingTimeInterval(10))

    XCTAssertEqual(store.active(now: t0.addingTimeInterval(20)).count, 2, "several timers run at once")
    XCTAssertEqual(store.active(now: t0.addingTimeInterval(20))[0].label, "Noodles")
    XCTAssertEqual(store.active(now: t0.addingTimeInterval(20))[1].remainingSeconds(from: t0.addingTimeInterval(20)), 290, accuracy: 0.001)
  }

  func testCreateNeverAcknowledgesBeforeCreation() {
    var store = CookTimerStore()
    XCTAssertNil(store.create(id: "a", sessionID: session, label: "x", durationSeconds: 0, now: t0), "zero duration creates nothing")
    XCTAssertNil(store.create(id: "a", sessionID: session, label: "x", durationSeconds: -5, now: t0), "negative duration creates nothing")
    XCTAssertEqual(store.active(now: t0).count, 0)

    _ = store.create(id: "a", sessionID: session, label: "x", durationSeconds: 60, now: t0)
    let second = store.create(id: "a", sessionID: session, label: "y", durationSeconds: 60, now: t0)
    XCTAssertNil(second, "a duplicate id is rejected — the first timer stands")
    XCTAssertEqual(store.active(now: t0).count, 1)
    XCTAssertEqual(store.active(now: t0).first?.label, "x")
  }

  // MARK: - Adjust, pause, resume, remove

  func testAdjustMovesTheDeadline() {
    var store = CookTimerStore()
    _ = store.create(id: "a", sessionID: session, label: "Noodles", durationSeconds: 120, now: t0)
    let later = t0.addingTimeInterval(60)

    let effects = store.adjust(id: "a", durationSeconds: 300, now: later)
    XCTAssertEqual(effects, [.scheduleNotification(id: "a", deadline: later.addingTimeInterval(300))])
    XCTAssertEqual((store.active(now: later).first?.remainingSeconds(from: later) ?? -1), 300, accuracy: 0.001)

    XCTAssertNil(store.adjust(id: "missing", durationSeconds: 60, now: later))
    XCTAssertNil(store.adjust(id: "a", durationSeconds: 0, now: later))
  }

  func testPauseFreezesRemainingAndCancelsTheNotification() {
    var store = CookTimerStore()
    _ = store.create(id: "a", sessionID: session, label: "Noodles", durationSeconds: 120, now: t0)
    let pauseAt = t0.addingTimeInterval(50)

    let effects = store.pause(id: "a", now: pauseAt)
    XCTAssertEqual(effects, [.cancelNotification(id: "a")])

    let timer = store.active(now: pauseAt).first
    XCTAssertEqual((timer?.remainingSeconds(from: pauseAt) ?? -1), 70, accuracy: 0.001)
    XCTAssertEqual((timer?.remainingSeconds(from: pauseAt.addingTimeInterval(1000)) ?? -1), 70, accuracy: 0.001, "a paused timer does not drain")
    XCTAssertTrue(timer?.isPaused ?? false)
  }

  func testResumeRecomputesANewAbsoluteDeadline() {
    var store = CookTimerStore()
    _ = store.create(id: "a", sessionID: session, label: "Noodles", durationSeconds: 120, now: t0)
    _ = store.pause(id: "a", now: t0.addingTimeInterval(50))

    let resumeAt = t0.addingTimeInterval(500)
    let effects = store.resume(id: "a", now: resumeAt)
    XCTAssertEqual(effects, [.scheduleNotification(id: "a", deadline: resumeAt.addingTimeInterval(70))])
    XCTAssertEqual((store.active(now: resumeAt).first?.remainingSeconds(from: resumeAt) ?? -1), 70, accuracy: 0.001)
    XCTAssertFalse(store.active(now: resumeAt).first?.isPaused ?? true)
  }

  func testRemoveCancelsAndDrops() {
    var store = CookTimerStore()
    _ = store.create(id: "a", sessionID: session, label: "Noodles", durationSeconds: 120, now: t0)
    XCTAssertEqual(store.remove(id: "a"), [.cancelNotification(id: "a")])
    XCTAssertEqual(store.active(now: t0).count, 0)
    XCTAssertNil(store.remove(id: "a"))
  }

  // MARK: - Firing

  func testPendingFiredListsUnacknowledgedFiredTimersOldestFirst() {
    var store = CookTimerStore()
    _ = store.create(id: "late", sessionID: session, label: "Noodles", durationSeconds: 60, now: t0)
    _ = store.create(id: "later", sessionID: session, label: "Eggs", durationSeconds: 300, now: t0)

    let before = t0.addingTimeInterval(61)
    XCTAssertEqual(store.pendingFired(now: before).map(\.id), ["late"])

    store.acknowledge(id: "late", at: before)
    XCTAssertEqual(store.pendingFired(now: before).map(\.id), [], "acknowledged timers stop presenting as pending")

    let after = t0.addingTimeInterval(400)
    XCTAssertEqual(store.pendingFired(now: after).map(\.id), ["later"])
    XCTAssertTrue(store.active(now: after).first(where: { $0.id == "later" })?.isFired(at: after) ?? false)
  }

  func testPausedTimersDoNotFire() {
    var store = CookTimerStore()
    _ = store.create(id: "a", sessionID: session, label: "Noodles", durationSeconds: 60, now: t0)
    _ = store.pause(id: "a", now: t0.addingTimeInterval(10))

    XCTAssertTrue(store.pendingFired(now: t0.addingTimeInterval(3600)).isEmpty, "a paused timer with a passed deadline stays paused, not fired")
  }

  // MARK: - App kill / relaunch

  func testTimersSurviveAKillThroughJSONRoundTrip() throws {
    var store = CookTimerStore()
    _ = store.create(id: "noodles", sessionID: session, label: "Noodles", durationSeconds: 120, now: t0)
    _ = store.create(id: "eggs", sessionID: session, label: "Eggs", durationSeconds: 300, now: t0)
    _ = store.pause(id: "eggs", now: t0.addingTimeInterval(30))

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let persisted = try encoder.encode(store)

    // The app relaunches four minutes later; the deadline passed while dead.
    let relaunchAt = t0.addingTimeInterval(300)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(CookTimerStore.self, from: persisted)

    // remaining = deadline − now, recomputed from the absolute deadline.
    let noodles = restored.active(now: relaunchAt).first { $0.id == "noodles" }
    XCTAssertEqual((noodles?.remainingSeconds(from: relaunchAt) ?? -1), 0, accuracy: 0.001)

    // A deadline that passed while dead presents as fired — the notification did its job.
    XCTAssertEqual(restored.pendingFired(now: relaunchAt).map(\.id), ["noodles"])

    // The paused timer resumes with its frozen remainder.
    let eggs = restored.active(now: relaunchAt).first { $0.id == "eggs" }
    XCTAssertEqual((eggs?.remainingSeconds(from: relaunchAt) ?? -1), 270, accuracy: 0.001)
    var resumable = restored
    let effects = resumable.resume(id: "eggs", now: relaunchAt)
    XCTAssertEqual(effects, [.scheduleNotification(id: "eggs", deadline: relaunchAt.addingTimeInterval(270))])
  }

  func testFiredWhileDeadStaysFiredAfterAcknowledgeRoundTrip() throws {
    var store = CookTimerStore()
    _ = store.create(id: "noodles", sessionID: session, label: "Noodles", durationSeconds: 60, now: t0)
    let killAt = t0.addingTimeInterval(120)
    store.acknowledge(id: "noodles", at: killAt)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let persisted = try encoder.encode(store)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(CookTimerStore.self, from: persisted)

    XCTAssertTrue(restored.pendingFired(now: t0.addingTimeInterval(200)).isEmpty, "an acknowledged timer stays acknowledged across a kill")
  }

  // MARK: - Clock changes (LeChef §4.4)

  func testClockJumpClassification() {
    XCTAssertEqual(CookTimerStore.classifyClockJump(lastKnown: t0, now: t0.addingTimeInterval(30)), .none)
    XCTAssertEqual(CookTimerStore.classifyClockJump(lastKnown: t0, now: t0.addingTimeInterval(3600)), .forward)
    XCTAssertEqual(CookTimerStore.classifyClockJump(lastKnown: t0, now: t0.addingTimeInterval(-3600)), .backward)
  }

  func testBackwardsJumpPausesAllRunningTimersAndAsks() {
    var store = CookTimerStore()
    _ = store.create(id: "a", sessionID: session, label: "Noodles", durationSeconds: 600, now: t0)
    _ = store.create(id: "b", sessionID: session, label: "Eggs", durationSeconds: 1200, now: t0)
    _ = store.pause(id: "b", now: t0.addingTimeInterval(10))

    // The clock jumps back an hour; running timers pause and the app asks. The remainder is
    // frozen as of the last trusted clock (t0), not the jumped-back one.
    let jumpedTo = t0.addingTimeInterval(-3600)
    let effects = store.pauseAll(now: jumpedTo, frozenAsOf: t0)
    XCTAssertEqual(effects, [.cancelNotification(id: "a")], "only the running timer needs cancelling")

    let a = store.active(now: jumpedTo).first { $0.id == "a" }
    XCTAssertTrue(a?.isPaused ?? false)
    XCTAssertEqual((a?.remainingSeconds(from: jumpedTo) ?? -1), 600, accuracy: 0.001, "the frozen remainder is kept")
  }
}
