import XCTest

@testable import FLFeatureLogic
@testable import FridgeLuck

/// What the taste profile screen shows. `TasteProfileView` draws
/// `TasteProfileScreenContent` and nothing else, and every row button goes through
/// `TasteProfileViewModel.perform`, so these drive the real view model over a fake
/// `TasteProfileServicing` and check the content the screen renders.
@MainActor
final class TasteProfileScreenTests: XCTestCase {
  /// 2026-10-23 12:00 UTC.
  private static let now = Date(timeIntervalSince1970: 1_792_756_800)
  private static let day: TimeInterval = 86_400

  private var service: StatefulTasteProfileService!

  override func setUp() async throws {
    service = StatefulTasteProfileService()
  }

  private func makeViewModel() -> TasteProfileViewModel {
    let now = Self.now
    return TasteProfileViewModel(service: service, now: { now })
  }

  private func content(_ viewModel: TasteProfileViewModel) -> TasteProfileScreenContent {
    TasteProfileScreenContent.make(
      from: viewModel, now: Self.now, locale: Locale(identifier: "en_US"),
      timeZone: TimeZone(identifier: "UTC")!)
  }

  private func loadedSections(
    _ viewModel: TasteProfileViewModel, file: StaticString = #filePath, line: UInt = #line
  ) -> [TasteProfileScreenContent.Section] {
    guard case .loaded(let sections, _) = content(viewModel) else {
      XCTFail("expected loaded content, got \(content(viewModel))", file: file, line: line)
      return []
    }
    return sections
  }

  private func statement(
    id: String,
    layer: TasteProfileStatementLayer = .inferred,
    state: TasteProfileStatementState = .active,
    numerator: Int? = nil,
    denominator: Int? = nil,
    lastEvidenceAt: Date? = nil,
    mutedUntil: Date? = nil,
    text: String
  ) -> TasteProfileStatementValue {
    TasteProfileStatementValue(
      id: id, layer: layer, featureKind: .ingredient, featureKey: "ingredient:\(id)",
      templateId: "test.\(id)", numerator: numerator, denominator: denominator,
      state: state, mutedUntil: mutedUntil, pinnedValue: nil, lastEvidenceAt: lastEvidenceAt,
      createdAt: Self.now, updatedAt: Self.now, text: text)
  }

  private var restriction: TasteProfileStatementValue {
    statement(
      id: "peanut", layer: .restriction,
      text: "No peanut. Set at setup, edited in setup only.")
  }

  private var coriander: TasteProfileStatementValue {
    statement(
      id: "coriander", numerator: 4, denominator: 5,
      lastEvidenceAt: Self.now.addingTimeInterval(-11 * Self.day),
      text:
        "You go off coriander: 4 of the 5 recipes you cooked with it were rated 2 stars or below."
    )
  }

  // MARK: - States

  func testBeforeTheFirstLoadFinishesTheScreenShowsLoadingNotEmpty() {
    XCTAssertEqual(content(makeViewModel()), .loading)
  }

  func testAProfileWithNothingInItShowsTheEmptyState() async {
    let viewModel = makeViewModel()
    await viewModel.load()

    XCTAssertEqual(content(viewModel), .empty)
    XCTAssertEqual(TasteProfileScreenContent.emptyTitle, "Nothing learned yet")
    XCTAssertTrue(TasteProfileScreenContent.emptyMessage.hasPrefix("Cook a few meals"))
  }

  func testALoadFailureShowsTheErrorStateAndRetryRecovers() async {
    service.loadError = NSError(domain: "test", code: 1)
    service.statements = [coriander]
    let viewModel = makeViewModel()
    await viewModel.load()
    XCTAssertEqual(content(viewModel), .failed)

    // Retry calls load() again.
    service.loadError = nil
    await viewModel.load()
    XCTAssertEqual(loadedSections(viewModel).map(\.id), [.learned])
  }

  // MARK: - Rows and actions

  func testSectionsRenderEachSentenceWithItsEvidenceAndActions() async {
    service.statements = [
      restriction,
      coriander,
      statement(id: "tofu", state: .rejected, numerator: 3, denominator: 3, text: "tofu line"),
      statement(
        id: "okra", state: .muted, mutedUntil: Self.now.addingTimeInterval(90 * Self.day),
        text: "okra line"),
    ]
    let viewModel = makeViewModel()
    await viewModel.load()
    let sections = loadedSections(viewModel)

    XCTAssertEqual(sections.map(\.id), [.restrictions, .learned, .corrections])

    let learned = sections[1].rows
    XCTAssertEqual(learned.map(\.id), ["coriander"])
    XCTAssertEqual(learned[0].sentence, coriander.text)
    XCTAssertEqual(learned[0].detail, "4 of 5 times · last Oct 12")
    XCTAssertEqual(learned[0].actions, [.markWrong, .dontAskAgain])
    XCTAssertFalse(learned[0].isStruckThrough)
    XCTAssertEqual(
      learned[0].accessibilityLabel,
      "\(coriander.text). 4 of 5 times, most recently October 12")

    let corrected = sections[2].rows
    XCTAssertEqual(corrected.map(\.id), ["tofu", "okra"])
    XCTAssertEqual(corrected[0].detail, "Marked wrong")
    XCTAssertTrue(corrected[0].isStruckThrough)
    XCTAssertEqual(corrected[0].actions, [.reopen])
    XCTAssertEqual(corrected[1].detail, "Hidden until Jan 21, 2027")
    XCTAssertEqual(corrected[1].actions, [.reopen])
  }

  func testARestrictionRowOffersNoDismissActionAndLinksToFoodPreferences() async {
    service.statements = [
      restriction,
      statement(id: "vegan", layer: .restriction, state: .confirmed, text: "No meat."),
    ]
    let viewModel = makeViewModel()
    await viewModel.load()
    let restrictions = loadedSections(viewModel).first { $0.id == .restrictions }

    XCTAssertEqual(restrictions?.rows.map(\.id), ["peanut", "vegan"])
    XCTAssertEqual(restrictions?.rows.map(\.actions), [[], []])
    XCTAssertEqual(restrictions?.rows.map(\.detail), [nil, nil])
    XCTAssertEqual(restrictions?.linksToFoodPreferences, true)
  }

  func testWithOnlyRestrictionsTheLearnedSectionStillSaysWhatWillAppear() async {
    service.statements = [restriction]
    let viewModel = makeViewModel()
    await viewModel.load()
    let learned = loadedSections(viewModel).first { $0.id == .learned }

    XCTAssertEqual(learned?.rows, [])
    XCTAssertEqual(learned?.placeholder, TasteProfileScreenContent.learnedPlaceholder)
  }

  // MARK: - Corrections

  func testThisIsWrongMarksTheRowWrongAndMovesItToCorrected() async {
    service.statements = [coriander]
    let viewModel = makeViewModel()
    await viewModel.load()
    let row = loadedSections(viewModel)[0].rows[0]

    await viewModel.perform(.markWrong, on: row.source)

    XCTAssertEqual(service.markWrongIds, ["coriander"])
    let sections = loadedSections(viewModel)
    XCTAssertEqual(sections.first { $0.id == .learned }?.rows, [])
    let moved = sections.first { $0.id == .corrections }?.rows
    XCTAssertEqual(moved?.map(\.id), ["coriander"])
    XCTAssertEqual(moved?.first?.isStruckThrough, true)
    XCTAssertEqual(moved?.first?.actions, [.reopen])
  }

  func testDontAskAgainHidesTheRowForTheNinetyDaysTheButtonStates() async {
    service.statements = [coriander]
    let viewModel = makeViewModel()
    await viewModel.load()
    let row = loadedSections(viewModel)[0].rows[0]

    await viewModel.perform(.dontAskAgain, on: row.source)

    XCTAssertEqual(service.mutes.map(\.id), ["coriander"])
    XCTAssertEqual(service.mutes.first?.until, Self.now.addingTimeInterval(90 * Self.day))
    XCTAssertTrue(TasteProfileRowAction.dontAskAgain.accessibilityHint.contains("90 days"))
    let moved = loadedSections(viewModel).first { $0.id == .corrections }?.rows
    XCTAssertEqual(moved?.first?.detail, "Hidden until Jan 21, 2027")
  }

  func testReopenPutsACorrectedRowBack() async {
    service.statements = [
      statement(id: "tofu", state: .rejected, numerator: 3, denominator: 3, text: "tofu line")
    ]
    let viewModel = makeViewModel()
    await viewModel.load()
    let row = loadedSections(viewModel)[0].rows[0]

    await viewModel.perform(.reopen, on: row.source)

    XCTAssertEqual(service.reopenIds, ["tofu"])
    XCTAssertEqual(
      loadedSections(viewModel).first { $0.id == .learned }?.rows.map(\.id), ["tofu"])
  }

  func testAFailedCorrectionKeepsTheRowsAndShowsTheError() async {
    service.statements = [coriander]
    let viewModel = makeViewModel()
    await viewModel.load()
    let row = loadedSections(viewModel)[0].rows[0]

    service.actionError = NSError(domain: "test", code: 2)
    await viewModel.perform(.markWrong, on: row.source)

    guard case .loaded(let sections, let actionError) = content(viewModel) else {
      return XCTFail("a failed correction must not replace the page")
    }
    XCTAssertEqual(actionError, "Couldn't apply that. Try again.")
    XCTAssertEqual(sections.first { $0.id == .learned }?.rows.map(\.id), ["coriander"])
  }
}

// MARK: - Fake service

/// Applies corrections to its own statements, the way the repository does, so the reload
/// after an action shows where the row went.
private final class StatefulTasteProfileService: TasteProfileServicing, @unchecked Sendable {
  var statements: [TasteProfileStatementValue] = []
  var loadError: Error?
  var actionError: Error?

  private(set) var markWrongIds: [String] = []
  private(set) var mutes: [(id: String, until: Date?)] = []
  private(set) var reopenIds: [String] = []

  func loadProfile(now: Date) async throws -> TasteProfilePage {
    if let loadError { throw loadError }
    return TasteProfilePage(statements: statements, hidden: [])
  }

  func markWrong(statementId: String, now: Date) async throws {
    if let actionError { throw actionError }
    markWrongIds.append(statementId)
    update(statementId) { $0.state = .rejected }
  }

  func markDontAskAgain(statementId: String, mutedUntil: Date?, now: Date) async throws {
    if let actionError { throw actionError }
    mutes.append((statementId, mutedUntil))
    update(statementId) {
      $0.state = .muted
      $0.mutedUntil = mutedUntil
    }
  }

  func reopen(statementId: String, now: Date) async throws {
    if let actionError { throw actionError }
    reopenIds.append(statementId)
    update(statementId) {
      $0.state = .active
      $0.mutedUntil = nil
    }
  }

  private func update(_ id: String, _ change: (inout TasteProfileStatementValue) -> Void) {
    guard let index = statements.firstIndex(where: { $0.id == id }) else { return }
    change(&statements[index])
  }
}
