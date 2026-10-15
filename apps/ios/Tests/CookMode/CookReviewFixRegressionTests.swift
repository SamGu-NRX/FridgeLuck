import FLFeatureLogic
import GRDB
import XCTest

/// Regression coverage for the PR #157 review round: persistent receipt round-trips through
/// the real GRDB store, stated-duration fraction math, timer totals for the drain ring,
/// one timer per voice command, the guide-driven session lifecycle, and replacing a foreign
/// active session.
final class CookReviewFixRegressionTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

  private func migratedStore() throws -> (CookSessionStore, DatabaseQueue) {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return (CookSessionStore(db: db), db)
  }

  private func makeRecipe(id: Int64) -> Recipe {
    Recipe(
      id: id, title: "Udon", timeMinutes: 20, servings: 2,
      instructions: "1. Boil the broth\n2. Add the noodles\n3. Serve hot", tags: 0,
      source: .catalog, createdAt: nil)
  }

  private func makeViewModel(
    recipe: Recipe, store: CookSessionStore, scheduler: RecordingScheduler
  ) -> CookModeViewModel {
    CookModeViewModel(
      recipe: recipe, logsMeal: false,
      dependencies: .init(
        store: store,
        substitutionOptions: { [] },
        substituteIsAllergen: { _ in nil },
        logMeal: { _, _, _, _ in },
        scaleLines: { [] },
        now: { self.t0 },
        newID: { UUID().uuidString.lowercased() },
        scheduler: scheduler))
  }

  private func count(_ db: DatabaseQueue, _ sql: String) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: sql) } ?? 0
  }

  // MARK: F1 — receipts persist against a real session reference

  func testRecordedReceiptComesBackFromPersistentLog() throws {
    let (store, db) = try migratedStore()

    let started = CookSessionReducer.reduce(
      .idle,
      .start(
        CookSessionEvent.Start(
          id: "sess_reg", recipeRef: CookRecipeRef(source: .catalog, id: "42", revision: 1),
          servings: 2, eaterIDs: [],
          steps: [CookStep(text: "Boil"), CookStep(text: "Serve")], now: t0))
    ).session
    try store.persist(session: started, timers: CookTimerStore())

    let log = CookReceiptLog(
      store: store, sessionID: started.id, sessionRevision: started.revision)
    log.record(
      CookReceiptRecord(
        proposalID: "prop_f1", payloadHash: "sha256:abc", state: .executed, recordedAt: t0))
    XCTAssertNil(log.lastRecordError, "the receipt write must succeed against the live session")

    let loaded = log.receipt(proposalID: "prop_f1")
    XCTAssertNotNil(loaded, "receipt must persist")
    XCTAssertEqual(loaded?.payloadHash, "sha256:abc")
    XCTAssertEqual(loaded?.state, .executed)
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cook_receipt"), 1)
  }

  func testStoreRejectsReceiptWithUnknownSession() throws {
    let (store, _) = try migratedStore()
    let log = CookReceiptLog(store: store, sessionID: "sess_missing", sessionRevision: 1)

    log.record(
      CookReceiptRecord(
        proposalID: "prop_none", payloadHash: "sha256:abc", state: .executed, recordedAt: t0))
    XCTAssertNotNil(log.lastRecordError, "an FK-violating write surfaces, never swallows")
    XCTAssertNil(log.receipt(proposalID: "prop_none"))
  }

  // MARK: F3 — stated-duration fractions are of the stated unit

  func testParsedStatedDurationAddsFractionInUnits() {
    XCTAssertEqual(CookStepParsing.parsedTimerSeconds(in: "Simmer for 2 and a half minutes"), 150)
    XCTAssertEqual(CookStepParsing.parsedTimerSeconds(in: "Roast for 1 and a half hours"), 5400)
    XCTAssertEqual(CookStepParsing.parsedTimerSeconds(in: "Chill for 1 and a quarter hours"), 4500)
    XCTAssertEqual(CookStepParsing.parsedTimerSeconds(in: "Boil for 3 minutes"), 180)
    XCTAssertNil(CookStepParsing.parsedTimerSeconds(in: "2 minutes per side"))
  }

  // MARK: F6 — created timers carry totalSeconds for the drain ring

  func testCreateSetsTotalSecondsForTheDrainRing() {
    var timers = CookTimerStore()
    let created = timers.create(
      id: "t1", sessionID: "sess_reg", label: "Broth", durationSeconds: 90, now: t0)
    XCTAssertEqual(created?.timer.totalSeconds, 90)
    XCTAssertEqual(created?.timer.remainingSeconds(from: t0.addingTimeInterval(30)), 60)
  }

  // MARK: F4 — one voice timer command creates exactly one timer

  func testVoiceTimerCommandCreatesExactlyOneTimer() throws {
    let (store, db) = try migratedStore()
    let vm = makeViewModel(
      recipe: makeRecipe(id: 42), store: store, scheduler: RecordingScheduler())
    vm.startOrResume()

    vm.send(.timer(seconds: 90))

    XCTAssertEqual(vm.session.timers.count, 1, "the reducer created the timer exactly once")
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cook_timer"), 1, "and it persisted once")
  }

  // MARK: F2 — the guide's lifecycle terminalizes the session

  func testCompletePersistsTheSessionTerminal() throws {
    let (store, _) = try migratedStore()
    let vm = makeViewModel(
      recipe: makeRecipe(id: 42), store: store, scheduler: RecordingScheduler())
    vm.startOrResume()
    XCTAssertEqual(vm.session.phase, .cooking)

    vm.complete()

    XCTAssertEqual(vm.session.phase, .completed)
    XCTAssertNil(try store.loadActiveSession(), "a completed session is no longer active")
    XCTAssertNil(vm.lastPersistError)
  }

  func testCelebrationDismissalSkipsRememberAndPersistsTerminal() throws {
    let (store, db) = try migratedStore()
    let vm = makeViewModel(
      recipe: makeRecipe(id: 42), store: store, scheduler: RecordingScheduler())
    vm.startOrResume()

    vm.complete()
    vm.skipRemember()

    XCTAssertEqual(vm.session.phase, .completed)
    XCTAssertNil(try store.loadActiveSession())
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cook_remember"), 1, "the skip is recorded")
    XCTAssertNil(vm.lastPersistError)
  }

  func testForeignActiveSessionIsAbandonedBeforeStartingNew() throws {
    let (store, _) = try migratedStore()

    // Another recipe is mid-cook with a live timer.
    let foreign = CookSessionReducer.reduce(
      .idle,
      .start(
        CookSessionEvent.Start(
          id: "sess_foreign", recipeRef: CookRecipeRef(source: .catalog, id: "999", revision: 1),
          servings: 2, eaterIDs: [], steps: [CookStep(text: "Old")], now: t0))
    ).session
    var foreignTimers = CookTimerStore()
    _ = foreignTimers.create(
      id: "t_old", sessionID: foreign.id, label: "Old", durationSeconds: 60, now: t0)
    try store.persist(session: foreign, timers: foreignTimers)

    let scheduler = RecordingScheduler()
    let vm = makeViewModel(recipe: makeRecipe(id: 42), store: store, scheduler: scheduler)
    vm.startOrResume()

    XCTAssertEqual(vm.session.recipeRef?.id, "42")
    XCTAssertEqual(
      try store.loadActiveSession()?.session.recipeRef?.id, "42",
      "the foreign cooking row was replaced by this session")
    XCTAssertTrue(vm.timerStore.timers.isEmpty, "no foreign timer leaks into the new session")
    XCTAssertTrue(
      scheduler.cancelled.contains("t_old"), "the foreign timer's notification cancelled")
    XCTAssertNil(vm.lastPersistError, "starting a new recipe never wedges persistence")
  }
}

/// Records schedule and cancel calls — no user notifications in tests.
final class RecordingScheduler: CookTimerScheduling {
  private(set) var scheduled: [(id: String, label: String, deadline: Date)] = []
  private(set) var cancelled: [String] = []

  func schedule(id: String, label: String, deadline: Date) {
    scheduled.append((id, label, deadline))
  }

  func cancel(id: String) {
    cancelled.append(id)
  }
}
