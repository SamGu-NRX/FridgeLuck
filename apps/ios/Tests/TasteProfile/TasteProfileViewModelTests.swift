import XCTest

@testable import FLFeatureLogic
#if canImport(FridgeLuck)
@testable import FridgeLuck
#else
// Portable Linux check (Tools/taste-store-check): the same sources live in the
// TasteStoreCheck mirror module instead of the app target.
@testable import TasteStoreCheck
#endif

/// The taste profile view model: section mapping, hidden insights, loading/error/empty
/// states, and the correction actions delegating to persistence. The service is faked,
/// so these run without GRDB.
@MainActor
final class TasteProfileViewModelTests: XCTestCase {
  private var service: FakeTasteProfileService!

  override func setUp() async throws {
    // (super.setUp() is not required for async teardown-free fixtures)
    service = FakeTasteProfileService()
  }

  private func makeViewModel() -> TasteProfileViewModel {
    TasteProfileViewModel(service: service)
  }

  private func statement(
    id: String = "stmt-1",
    layer: TasteProfileStatementLayer = .inferred,
    state: TasteProfileStatementState = .active,
    numerator: Int? = 3,
    denominator: Int? = 3,
    text: String = "You seem to go off coriander."
  ) -> TasteProfileStatementValue {
    TasteProfileStatementValue(
      id: id, layer: layer, featureKind: .ingredient, featureKey: "ingredient:101",
      templateId: "taste.lowrating.hedged", numerator: numerator, denominator: denominator,
      state: state, mutedUntil: nil, pinnedValue: nil, lastEvidenceAt: nil,
      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
      text: text)
  }

  // MARK: - Loading

  func testLoadMapsSectionsInDisplayOrder() async {
    service.nextPage = TasteProfilePage(
      statements: [
        statement(id: "r", layer: .restriction, numerator: nil, denominator: nil),
        statement(id: "s", layer: .stated, numerator: nil, denominator: nil),
        statement(id: "p", layer: .pinned, state: .muted, numerator: nil, denominator: nil),
        statement(id: "a", state: .active),
        statement(id: "c", state: .confirmed),
        statement(id: "j", state: .rejected, text: "wrong one"),
      ],
      hidden: [])
    let vm = makeViewModel()
    await vm.load()

    XCTAssertFalse(vm.isLoading)
    XCTAssertNil(vm.errorMessage)
    let ids = vm.sections.map(\.id)
    XCTAssertEqual(
      ids, [.restrictions, .stated, .pinned, .learned, .corrections])
    XCTAssertEqual(vm.sections.first { $0.id == .learned }?.rows.map(\.id), ["a", "c"])
    XCTAssertEqual(vm.sections.first { $0.id == .corrections }?.rows.map(\.id), ["j"])
    XCTAssertEqual(vm.sections.first { $0.id == .pinned }?.rows.map(\.id), ["p"])
  }

  func testExpiredStatementsStayHiddenFromSections() async {
    service.nextPage = TasteProfilePage(
      statements: [statement(id: "e", state: .expired)], hidden: [])
    let vm = makeViewModel()
    await vm.load()
    XCTAssertTrue(vm.sections.allSatisfy { $0.rows.isEmpty })
  }

  func testHiddenInsightsAreExposedForTheEvidenceDetail() async {
    let hidden = TasteHiddenProfileItem(
      featureKey: "ingredient:101", claim: .lowRating, reason: .thinEvidence,
      numerator: 1, denominator: 2)
    service.nextPage = TasteProfilePage(statements: [], hidden: [hidden])
    let vm = makeViewModel()
    await vm.load()
    XCTAssertEqual(vm.hiddenInsights, [hidden])
  }

  func testLoadFailureShowsErrorAndClearsState() async {
    service.nextError = NSError(domain: "test", code: 1)
    let vm = makeViewModel()
    await vm.load()

    XCTAssertEqual(vm.errorMessage, "Couldn't load your taste profile. Try again.")
    XCTAssertTrue(vm.sections.allSatisfy { $0.rows.isEmpty })
    XCTAssertFalse(vm.isLoading)
  }

  func testEmptyPageIsEmpty() async {
    service.nextPage = TasteProfilePage(statements: [], hidden: [])
    let vm = makeViewModel()
    await vm.load()
    XCTAssertTrue(vm.isEmpty)
  }

  // MARK: - Correction actions

  func testMarkWrongDelegatesAndReloads() async {
    let active = statement(id: "a", state: .active)
    service.nextPage = TasteProfilePage(
      statements: [active, statement(id: "a", state: .rejected, text: "struck")], hidden: [])
    let vm = makeViewModel()
    await vm.load()
    XCTAssertEqual(service.markWrongCallCount, 0)

    await vm.markWrong(vm.sections.first { $0.id == .learned }!.rows[0])

    XCTAssertEqual(service.markWrongIds, ["a"])
    XCTAssertEqual(service.markWrongCallCount, 1)
    XCTAssertEqual(
      vm.sections.first { $0.id == .corrections }?.rows.map(\.id), ["a"])
    XCTAssertNil(vm.errorMessage)
  }

  func testDontAskAgainDelegatesToTheService() async {
    service.nextPage = TasteProfilePage(statements: [statement(id: "a")], hidden: [])
    let vm = makeViewModel()
    await vm.load()

    await vm.dontAskAgain(vm.sections.first { $0.id == .learned }!.rows[0])

    XCTAssertEqual(service.dontAskAgainIds, ["a"])
    XCTAssertNil(vm.errorMessage)
  }

  func testReopenDelegatesToTheService() async {
    service.nextPage = TasteProfilePage(
      statements: [statement(id: "j", state: .rejected)], hidden: [])
    let vm = makeViewModel()
    await vm.load()

    await vm.reopen(vm.sections.first { $0.id == .corrections }!.rows[0])

    XCTAssertEqual(service.reopenIds, ["j"])
    XCTAssertNil(vm.errorMessage)
  }

  func testActionFailureShowsErrorWithoutChangingSections() async {
    service.nextPage = TasteProfilePage(statements: [statement(id: "a")], hidden: [])
    let vm = makeViewModel()
    await vm.load()
    let before = vm.sections

    service.nextError = NSError(domain: "test", code: 2)
    await vm.markWrong(vm.sections.first { $0.id == .learned }!.rows[0])

    XCTAssertEqual(vm.errorMessage, "Couldn't apply that. Try again.")
    XCTAssertEqual(vm.sections, before, "a failed action leaves the page unchanged")
  }

  // MARK: - Row affordances

  func testRowAffordancesFollowStateAndLayer() async {
    func row(
      layer: TasteProfileStatementLayer = .inferred, state: TasteProfileStatementState
    ) -> TasteProfileRow {
      TasteProfileViewModel.row(from: statement(layer: layer, state: state))
    }

    let active = row(state: .active)
    XCTAssertTrue(active.canMarkWrong)
    XCTAssertTrue(active.canDontAskAgain)
    XCTAssertFalse(active.canReopen)

    let confirmed = row(state: .confirmed)
    XCTAssertTrue(confirmed.canMarkWrong)

    let rejected = row(state: .rejected)
    XCTAssertFalse(rejected.canMarkWrong)
    XCTAssertFalse(rejected.canDontAskAgain)
    XCTAssertTrue(rejected.canReopen)

    let muted = row(state: .muted)
    XCTAssertTrue(muted.canReopen)

    // Restrictions are hard filters edited in Food Preferences: the profile page offers no
    // correction on them. A rejection here would not stick — loadProfile rebuilds them
    // from health_profile on every load.
    let restriction = row(layer: .restriction, state: .active)
    XCTAssertFalse(restriction.canMarkWrong)
    XCTAssertFalse(restriction.canDontAskAgain)
  }

  func testEvidenceDetailRendersTheCountsTheStatementStandsOn() async {
    let row = TasteProfileViewModel.row(
      from: statement(numerator: 3, denominator: 3))
    XCTAssertEqual(TasteProfileViewModel.evidenceDetail(for: row), "3 of 3")

    let restriction = TasteProfileViewModel.row(
      from: statement(numerator: nil, denominator: nil))
    XCTAssertNil(TasteProfileViewModel.evidenceDetail(for: restriction))
  }
}

// MARK: - Fake service

private final class FakeTasteProfileService: TasteProfileServicing, @unchecked Sendable {
  var nextPage = TasteProfilePage(statements: [], hidden: [])
  var nextError: Error?

  private(set) var markWrongIds: [String] = []
  private(set) var dontAskAgainIds: [String] = []
  private(set) var reopenIds: [String] = []

  var markWrongCallCount: Int { markWrongIds.count }

  func loadProfile(now: Date) async throws -> TasteProfilePage {
    if let nextError { throw nextError }
    return nextPage
  }

  func markWrong(statementId: String, now: Date) async throws {
    if let nextError { throw nextError }
    markWrongIds.append(statementId)
  }

  func markDontAskAgain(statementId: String, mutedUntil: Date?, now: Date) async throws {
    if let nextError { throw nextError }
    dontAskAgainIds.append(statementId)
  }

  func reopen(statementId: String, now: Date) async throws {
    if let nextError { throw nextError }
    reopenIds.append(statementId)
  }
}
