import GRDB
import XCTest

@testable import FLFeatureLogic
@testable import FridgeLuck

/// The cook flow applies the receipt contract's recheck before executing a
/// swap: a clean screen against a known composition executes, `unknown` and
/// `unsupported` refuse, and every attempt — refused or executed — records its
/// canonical recheck JSON beside the cook_substitution row. The session has no
/// eaters in these surfaces, so the recheck names the unnamed household.
@MainActor
final class CookSubstitutionRecheckFlowTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

  private func makeStore() throws -> (CookSessionStore, DatabaseQueue) {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return (CookSessionStore(db: db), db)
  }

  private func makeViewModel(
    store: CookSessionStore,
    recheck: ((Int64, Int64, [String]) -> CookSubstitutionRecheck)? = nil,
    booleanScreen: @escaping (Int64) -> Bool? = { _ in nil }
  ) -> CookModeViewModel {
    CookModeViewModel(
      recipe: Recipe(
        id: 2, title: "Udon", timeMinutes: 20, servings: 2,
        instructions: "1. Boil the broth\n2. Add the noodles\n3. Serve hot", tags: 0,
        source: .bundled, createdAt: nil),
      logsMeal: false,
      dependencies: .init(
        store: store,
        substitutionOptions: { _ in [] },
        substituteIsAllergen: booleanScreen,
        logMeal: { _, _, _, _ in },
        scaleLines: { [] },
        inventoryCorrection: nil,
        now: { self.t0 },
        newID: { UUID().uuidString.lowercased() },
        scheduler: CookModeViewModel.NoopTimerScheduler()))
  }

  private func startedViewModel(
    store: CookSessionStore,
    recheck: ((Int64, Int64, [String]) -> CookSubstitutionRecheck)? = nil,
    booleanScreen: @escaping (Int64) -> Bool? = { _ in nil }
  ) throws -> CookModeViewModel {
    let viewModel = makeViewModel(store: store, recheck: recheck, booleanScreen: booleanScreen)
    viewModel.startOrResume()
    return viewModel
  }

  private func substitution(substituteId: Int64 = 9001) -> Substitution {
    Substitution(
      originalId: 2, substituteId: substituteId, substituteKey: "", reasons: [], ratio: 1.0,
      note: "the packet's swap")
  }

  private func recordedRecheckJSON(_ db: DatabaseQueue) throws -> String? {
    try db.read { db in
      try String.fetchOne(db, sql: "SELECT allergen_recheck FROM cook_substitution")
    }
  }

  private func recordedRowCount(_ db: DatabaseQueue) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cook_substitution") } ?? 0
  }

  func testCleanScreenExecutesAndRecordsTheContractRecheck() throws {
    let (store, db) = try makeStore()
    var screenedSubstitute: (Int64, Int64, [String])?
    let viewModel = try startedViewModel(
      store: store,
      recheck: { original, substitute, eaters in
        screenedSubstitute = (original, substitute, eaters)
        return .verified(eaters: eaters)
      })

    let outcome = viewModel.applySubstitution(originalID: 2, substitute: substitution())

    XCTAssertEqual(outcome.executed, true, "a verified recheck executes the swap")
    XCTAssertEqual(
      outcome.recheckJSON,
      "{\"verdict\":\"verified\",\"eaters\":[\"household\"],\"blockedPath\":null}")
    XCTAssertEqual(
      screenedSubstitute?.0, 2, "the provider receives the original ingredient id")
    XCTAssertEqual(screenedSubstitute?.1, 9001, "the provider receives the substitute id")
    XCTAssertEqual(
      screenedSubstitute?.2, ["household"],
      "a session without eaterIDs screens the unnamed household")
    XCTAssertEqual(try recordedRowCount(db), 1, "the executed swap is recorded")
    XCTAssertEqual(
      try recordedRecheckJSON(db), outcome.recheckJSON,
      "the row stores the receipt's exact recheck bytes")
  }

  func testUnsupportedScreenRefusesAndRecordsTheRefusal() throws {
    let (store, db) = try makeStore()
    let viewModel = try startedViewModel(
      store: store,
      recheck: { _, _, eaters in
        CookSubstitutionRecheck(
          verdict: .unsupported, eaters: eaters, blockedPath: "Contains wheat via soy sauce")
      })

    let outcome = viewModel.applySubstitution(originalID: 2, substitute: substitution())

    XCTAssertEqual(outcome.executed, false, "an unsupported recheck refuses the swap")
    XCTAssertEqual(
      outcome.recheckJSON,
      "{\"verdict\":\"unsupported\",\"eaters\":[\"household\"],\"blockedPath\":\"Contains wheat via soy sauce\"}"
    )
    XCTAssertEqual(try recordedRowCount(db), 1, "the refusal is recorded, not silent")
    XCTAssertEqual(try recordedRecheckJSON(db), outcome.recheckJSON)
  }

  func testUnknownScreenFailsClosedWithTheUnknownPath() throws {
    let (store, db) = try makeStore()
    let viewModel = try startedViewModel(store: store)

    let outcome = viewModel.applySubstitution(originalID: 2, substitute: substitution())

    XCTAssertEqual(outcome.executed, false, "no provider and no screen: the swap refuses")
    XCTAssertEqual(
      outcome.recheckJSON,
      "{\"verdict\":\"unknown\",\"eaters\":[\"household\"],\"blockedPath\":\"composition unknown\"}"
    )
    XCTAssertEqual(try recordedRecheckJSON(db), outcome.recheckJSON)
  }

  func testBooleanScreenMapsOntoTheContractVerdicts() throws {
    let (store, db) = try makeStore()
    let blocked = try startedViewModel(store: store, booleanScreen: { _ in true })
    let blockedOutcome = blocked.applySubstitution(originalID: 2, substitute: substitution())
    XCTAssertEqual(blockedOutcome.executed, false)
    XCTAssertTrue(blockedOutcome.recheckJSON.contains("\"verdict\":\"unsupported\""))
    XCTAssertTrue(
      blockedOutcome.recheckJSON.contains("blocked by a household allergen"),
      "the boolean screen cannot name the group; the path stays honest about that")
    XCTAssertEqual(try recordedRecheckJSON(db), blockedOutcome.recheckJSON)

    let (clearStore, clearDB) = try makeStore()
    let cleared = try startedViewModel(store: clearStore, booleanScreen: { _ in false })
    let clearedOutcome = cleared.applySubstitution(originalID: 2, substitute: substitution())
    XCTAssertEqual(clearedOutcome.executed, true)
    XCTAssertTrue(clearedOutcome.recheckJSON.contains("\"verdict\":\"verified\""))
    XCTAssertEqual(try recordedRowCount(clearDB), 1)
  }

  func testSwapOutsideAnActiveSessionNeverReadsAsAPass() throws {
    let viewModel = makeViewModel(
      store: try makeStore().0,
      recheck: { _, _, _ in
        .verified(eaters: ["household"])
      })
    // No startOrResume: the session is idle, nothing was screened.

    let outcome = viewModel.applySubstitution(originalID: 2, substitute: substitution())

    XCTAssertEqual(outcome.executed, false, "an idle session refuses")
    XCTAssertTrue(
      outcome.recheckJSON.contains("\"verdict\":\"unknown\"")
        && outcome.recheckJSON.contains("did not run"),
      "the record must not read as a pass when no recheck ran")
  }

  func testSessionEatersNameTheRecheck() throws {
    let (store, db) = try makeStore()
    let viewModel = try startedViewModel(
      store: store,
      recheck: { _, _, eaters in
        CookSubstitutionRecheck(verdict: .verified, eaters: eaters, blockedPath: nil)
      })
    viewModel.installSubstitutionRecheck { _, _, eaters in
      CookSubstitutionRecheck(verdict: .verified, eaters: eaters, blockedPath: nil)
    }

    let outcome = viewModel.applySubstitution(originalID: 2, substitute: substitution())

    XCTAssertEqual(outcome.executed, true)
    XCTAssertEqual(
      try recordedRecheckJSON(db), outcome.recheckJSON,
      "the installed provider wins over the init-time one")
  }
}
