import FLBarcode
import XCTest

private actor StubLookup: BarcodeProductLookup {
  var calls = 0
  let handler: @Sendable (ValidatedGTIN) async throws -> BarcodeLookupOutcome

  init(handler: @escaping @Sendable (ValidatedGTIN) async throws -> BarcodeLookupOutcome) {
    self.handler = handler
  }

  func lookup(gtin: ValidatedGTIN) async throws -> BarcodeLookupOutcome {
    calls += 1
    return try await handler(gtin)
  }
}

private struct StubResolver: BarcodeCatalogResolver {
  let handler: @Sendable (String?, String?) -> [CatalogCandidate]

  func candidates(for productName: String?, brands: String?) -> [CatalogCandidate] {
    handler(productName, brands)
  }
}

@MainActor
private final class CountingCommitter: BarcodeSessionCommitting {
  struct Call: Equatable {
    let sourceRef: String
    let itemCount: Int
    let measuredFlags: [Bool]
  }

  private(set) var calls: [Call] = []
  var shouldFail = false

  func commit(items: [BarcodeCommitItem], sourceRef: String) async throws -> Int {
    calls.append(
      Call(
        sourceRef: sourceRef,
        itemCount: items.count,
        measuredFlags: items.map(\.isMeasured)
      ))
    if shouldFail { throw SimulatedError.commit }
    return items.count
  }

  enum SimulatedError: Error {
    case commit
  }
}

/// The intake state machine against fakes: scan dedupe, evidence-only drafts, retry-safe
/// commit, and cancelled-capture safety.
@MainActor
final class IntakeCoordinatorTests: XCTestCase {
  private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

  private func makeProduct(
    code: String,
    name: String? = "Greek yogurt",
    quantity: String? = "500 g"
  ) -> BarcodeProduct {
    BarcodeProduct(
      gtin: code,
      productName: name,
      brands: nil,
      quantityText: quantity,
      servingText: nil,
      ingredientsText: nil,
      source: PinnedSource(
        sourceId: "openfoodfacts",
        sourceURL: "https://world.openfoodfacts.org/api/v2/product/\(code).json",
        license: "ODbL-1.0",
        attribution: "Contains Open Food Facts data.",
        retrievedAt: fixedNow
      )
    )
  }

  private func makeBoundResolver() -> StubResolver {
    StubResolver { name, _ in
      guard let name, !name.isEmpty else { return [] }
      return [CatalogCandidate(id: 42, name: "milk", score: 0.95)]
    }
  }

  func testInvalidGTINRejected() async {
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .miss }),
      resolver: StubResolver(handler: { _, _ in [] }),
      committer: CountingCommitter()
    )

    let outcome = await coordinator.accept(gtin: "1234")
    XCTAssertEqual(outcome, .invalidGTIN(.unsupportedLength(digitCount: 4)))
    XCTAssertTrue(coordinator.drafts.isEmpty)
  }

  /// The same product scanned twice (UPC-A, then its zero-padded GTIN-14) is one draft,
  /// and the second scan does not re-lookup.
  func testDuplicateScansDedupeToOneDraft() async {
    let lookup = StubLookup(handler: { _ in .miss })
    let coordinator = BarcodeIntakeCoordinator(
      lookup: lookup,
      resolver: StubResolver(handler: { _, _ in [] }),
      committer: CountingCommitter()
    )

    let first = await coordinator.accept(gtin: "036000291452")
    let second = await coordinator.accept(gtin: "00036000291452")

    guard case .added(let draftID) = first else { return XCTFail("expected added, got \(first)") }
    XCTAssertEqual(second, .duplicate(draftID))
    XCTAssertEqual(coordinator.drafts.count, 1)
    let calls = await lookup.calls
    XCTAssertEqual(calls, 1)
  }

  func testFreshProductDraftUsesExplicitMassAndBinding() async {
    let product = makeProduct(code: "00036000291452", quantity: "250 g")
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .fresh(product) }),
      resolver: makeBoundResolver(),
      committer: CountingCommitter()
    )

    _ = await coordinator.accept(gtin: "036000291452")

    guard let draft = coordinator.drafts.first else { return XCTFail("expected a draft") }
    XCTAssertEqual(draft.ingredientId, 42)
    XCTAssertEqual(draft.amountGrams, 250.0)
    XCTAssertTrue(draft.isMeasured)
    XCTAssertFalse(draft.isStale)
    XCTAssertEqual(draft.evidenceSummary, "250 g")
    XCTAssertTrue(draft.isResolvedForCommit)
  }

  /// A stale record still builds a draft (the data is usable), but it is marked stale.
  func testStaleProductDraftIsMarkedStale() async {
    let product = makeProduct(code: "00036000291452", quantity: "250 g")
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .stale(product) }),
      resolver: makeBoundResolver(),
      committer: CountingCommitter()
    )

    _ = await coordinator.accept(gtin: "036000291452")

    guard let draft = coordinator.drafts.first else { return XCTFail("expected a draft") }
    XCTAssertTrue(draft.isStale)
    XCTAssertEqual(draft.amountGrams, 250.0)
  }

  /// No mass evidence: the amount stays unknown — the user supplies it in review.
  func testMissingMassStaysUnknown() async {
    let product = makeProduct(code: "00036000291452", quantity: nil)
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .fresh(product) }),
      resolver: makeBoundResolver(),
      committer: CountingCommitter()
    )

    _ = await coordinator.accept(gtin: "036000291452")

    guard let draft = coordinator.drafts.first else { return XCTFail("expected a draft") }
    XCTAssertNil(draft.amountGrams)
    XCTAssertFalse(draft.isMeasured)
    XCTAssertFalse(draft.isResolvedForCommit)
  }

  /// Count-only and serving-only quantities never become grams, even with bound identity.
  func testCountAndServingQuantitiesNeverBecomeGrams() async {
    for quantity in ["6", "12 pack", "serving size 30 g", "$4.50", "500 ml"] {
      let product = makeProduct(code: "00036000291452", quantity: quantity)
      let coordinator = BarcodeIntakeCoordinator(
        lookup: StubLookup(handler: { _ in .fresh(product) }),
        resolver: makeBoundResolver(),
        committer: CountingCommitter()
      )

      _ = await coordinator.accept(gtin: "036000291452")

      guard let draft = coordinator.drafts.first else { return XCTFail("expected a draft") }
      XCTAssertNil(draft.amountGrams, quantity)
      XCTAssertFalse(draft.isResolvedForCommit, quantity)
    }
  }

  /// Two near-tied candidates: identity stays unresolved until the user picks.
  func testAmbiguousBindingNeedsUserPick() async {
    let product = makeProduct(code: "00036000291452", name: "Tomato pasta sauce", quantity: "400 g")
    let resolver = StubResolver { name, _ in
      guard let name, !name.isEmpty else { return [] }
      return [
        CatalogCandidate(id: 7, name: "tomato", score: 0.9),
        CatalogCandidate(id: 11, name: "pasta", score: 0.86),
      ]
    }
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .fresh(product) }),
      resolver: resolver,
      committer: CountingCommitter()
    )

    _ = await coordinator.accept(gtin: "036000291452")

    guard let draft = coordinator.drafts.first else { return XCTFail("expected a draft") }
    XCTAssertNil(draft.ingredientId)
    XCTAssertFalse(draft.isResolvedForCommit)
    guard case .ambiguous = draft.binding else {
      return XCTFail("expected ambiguous binding, got \(draft.binding)")
    }

    coordinator.pickIdentity(CatalogCandidate(id: 7, name: "tomato", score: 0.9), for: draft.id)
    XCTAssertTrue(coordinator.drafts.first!.isResolvedForCommit)
  }

  /// Double commit: the second call is a no-op — the committer saw one call.
  func testDoubleCommitIsRetrySafe() async {
    let committer = CountingCommitter()
    let product = makeProduct(code: "00036000291452", quantity: "250 g")
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .fresh(product) }),
      resolver: makeBoundResolver(),
      committer: committer,
      sourceRef: "barcode_update_test_ref"
    )

    _ = await coordinator.accept(gtin: "036000291452")

    let first = await coordinator.commitAll()
    let second = await coordinator.commitAll()

    XCTAssertEqual(first, .committed(1))
    XCTAssertEqual(second, .alreadyCommitted)
    XCTAssertEqual(committer.calls.count, 1)
    XCTAssertEqual(committer.calls.first?.sourceRef, "barcode_update_test_ref")
  }

  /// A failed commit can be retried; every attempt carries the same stable source ref,
  /// which is what makes the retry idempotent downstream.
  func testFailedCommitRetriesWithSameSourceRef() async {
    let committer = CountingCommitter()
    committer.shouldFail = true
    let product = makeProduct(code: "00036000291452", quantity: "250 g")
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .fresh(product) }),
      resolver: makeBoundResolver(),
      committer: committer
    )

    _ = await coordinator.accept(gtin: "036000291452")

    let failed = await coordinator.commitAll()
    guard case .failed = failed else { return XCTFail("expected failed, got \(failed)") }

    committer.shouldFail = false
    let retry = await coordinator.commitAll()
    XCTAssertEqual(retry, .committed(1))
    XCTAssertEqual(committer.calls.count, 2)
    XCTAssertEqual(committer.calls.map(\.sourceRef), [coordinator.sourceRef, coordinator.sourceRef])
    XCTAssertTrue(coordinator.sourceRef.hasPrefix("barcode_update_"))
  }

  func testNothingToCommit() async {
    let committer = CountingCommitter()
    let product = makeProduct(code: "00036000291452", quantity: nil)
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .fresh(product) }),
      resolver: makeBoundResolver(),
      committer: committer
    )

    _ = await coordinator.accept(gtin: "036000291452")

    let commit = await coordinator.commitAll()
    XCTAssertEqual(commit, .nothingToCommit)
    XCTAssertTrue(committer.calls.isEmpty)
  }

  /// Cancelled capture: drafts are dropped, nothing commits, and new scans are refused.
  func testCancelledCaptureNeverCommits() async {
    let committer = CountingCommitter()
    let product = makeProduct(code: "00036000291452", quantity: "250 g")
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .fresh(product) }),
      resolver: makeBoundResolver(),
      committer: committer
    )

    _ = await coordinator.accept(gtin: "036000291452")
    _ = await coordinator.accept(gtin: "4006381333931")
    coordinator.cancel()

    XCTAssertTrue(coordinator.drafts.isEmpty)
    let commit = await coordinator.commitAll()
    XCTAssertEqual(commit, .cancelled)
    XCTAssertTrue(committer.calls.isEmpty)
    let afterCancel = await coordinator.accept(gtin: "036000291452")
    XCTAssertEqual(afterCancel, .cancelled)
  }

  /// A user-set amount is entered, not measured — the distinction survives into the
  /// commit items.
  func testUserSetAmountIsNotMeasured() async {
    let committer = CountingCommitter()
    let product = makeProduct(code: "00036000291452", quantity: nil)
    let coordinator = BarcodeIntakeCoordinator(
      lookup: StubLookup(handler: { _ in .fresh(product) }),
      resolver: makeBoundResolver(),
      committer: committer
    )

    _ = await coordinator.accept(gtin: "036000291452")
    let draftID = coordinator.drafts.first!.id
    coordinator.setAmount(100, for: draftID)

    let commit = await coordinator.commitAll()
    XCTAssertEqual(commit, .committed(1))
    XCTAssertEqual(committer.calls.first?.measuredFlags, [false])
    XCTAssertEqual(committer.calls.first?.itemCount, 1)
  }
}
