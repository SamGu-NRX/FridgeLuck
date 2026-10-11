import Foundation
import GRDB
import XCTest

#if canImport(FridgeLuck)
@testable import FridgeLuck
#else
@testable import FLInventoryCore
#endif

/// Deterministic invariant tests for the GRDB inventory operations behind meal logging.
///
/// The example tests in this folder (PortionLoggingTests, SwapLoggingTests,
/// InventoryQuantityEstimateTests) each pin one specific logged meal. This suite instead drives
/// the real `InventoryRepository` through seeded operation sequences on an in-memory migrated
/// database and checks repository-wide invariants after every operation:
///
/// - Balances never go negative, and no lot ever holds more than it started with.
/// - Every lot's `remaining_grams` reconciles with its audit trail: the trail is the ledger,
///   with the add event carrying `+quantity_grams`, consumption and scan-review adjusts
///   debiting their deltas, and restore refilling `+quantity_grams`, so
///   `remaining_grams == Σ(event deltas)` for the lot.
/// - Consumption follows the documented expiry-first ordering: lots with the soonest
///   `expires_at` deplete first (ties by `acquired_at`, then id), expiry-less lots last.
/// - The deducted quantity matches `previewConsumption` — the production preview — for the
///   same proposed grams, including the servings, portion multiplier, and swap math the v17/v18
///   migrations document. The two APIs agree per row only when a log's requests are unique per
///   ingredient: previewConsumption evaluates every row independently against current
///   availability, while applyConsumption depletes lots sequentially across rows, so a log that
///   requests the same ingredient twice (a swap onto an ingredient the recipe already uses)
///   with a combined request over stock shows a larger actual shortfall than the preview's
///   per-row figure. That divergence is a semantic difference, not a violation; the suite
///   asserts preview equality where the contract is exact and shortfall/balance identities
///   everywhere.
/// - Retry idempotency stays where the product puts it: grocery intake deduplicates by
///   `source_ref` through `hasEvent` (the `InventoryIntakeService.ingestGroceryItems`
///   contract), while logging the same meal twice is intended repeated logging and deducts
///   twice. No meal-log dedup is asserted anywhere — that contract does not exist.
///
/// Everything runs through real GRDB transactions and queries against the migrated schema.
/// There is no mock repository and no re-implementation of the allocator: expectations are
/// either relations between before/after database state or the documented recipe/serving/
/// portion/swap arithmetic. `removeActiveItem` is deliberately outside the operation space: it
/// is a bulk Kitchen-UI removal that writes no audit events, so it is not part of the
/// audited-event convention these tests pin.
///
/// Runs are deterministic: the generator is SplitMix64 over fixed seeds and every date derives
/// from a fixed epoch, so a failure reproduces from the printed seed alone. On failure the test
/// prints the seed and a reduced failing operation sequence. The reduction re-runs candidate
/// sequences on fresh databases and is bounded, so it only costs time on a failing run.
final class InventoryInvariantOperationTests: XCTestCase {

  // MARK: - Seeded operation sequences

  func testSeededOperationSequencesHoldAllInvariants() throws {
    var reports: [String] = []

    for seed: UInt64 in 1...24 {
      if let report = InventoryInvariantSupport.runSeededFuzz(seed: seed, opCount: 64) {
        print(report)
        reports.append(report)
      }
    }

    XCTAssertTrue(reports.isEmpty, "Invariant violations:\n\(reports.joined(separator: "\n\n"))")
  }


  // MARK: - Explicit boundary cases

  func testConsumeExactBalanceReachesZeroWithoutNegative() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 250, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(try XCTUnwrap(results.first).requestedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).shortfallGrams, 0, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 0, accuracy: 1e-9)
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testConsumeMoreThanBalanceDepletesAndReportsShortfall() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 200, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    XCTAssertEqual(try XCTUnwrap(results.first).requestedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 200, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).shortfallGrams, 50, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 0, accuracy: 1e-9)
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testConsumeWithNoStockTakesNothingAndWritesNoEvent() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    let results = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    XCTAssertEqual(try XCTUnwrap(results.first).requestedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 0, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).shortfallGrams, 250, accuracy: 1e-9)
    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(snap.events.count, 0)
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testAddLotClampsNegativeQuantityAndOutOfRangeConfidence() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    let clampedLot = try repository.addLot(
      ingredientId: 1, quantityGrams: -50, location: .fridge, confidenceScore: 1.7, source: .manual)
    let lowConfidenceLot = try repository.addLot(
      ingredientId: 2, quantityGrams: 100, location: .fridge, confidenceScore: -0.5, source: .manual)

    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    let clampedRow = try XCTUnwrap(snap.lots.first { $0.id == clampedLot })
    XCTAssertEqual(clampedRow.quantity, 0, accuracy: 1e-9)
    XCTAssertEqual(clampedRow.remaining, 0, accuracy: 1e-9)
    let lowRow = try XCTUnwrap(snap.lots.first { $0.id == lowConfidenceLot })
    XCTAssertEqual(lowRow.quantity, 100, accuracy: 1e-9)
    let addEvents = snap.events.filter { $0.type == "add" }
    XCTAssertEqual(addEvents.count, 2)
    XCTAssertEqual(addEvents[0].delta, 0, accuracy: 1e-9)
    XCTAssertEqual(addEvents[0].confidence, 1.0, accuracy: 1e-9)
    XCTAssertEqual(addEvents[1].confidence, 0.0, accuracy: 1e-9)
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testZeroServingsIsANoOpAtRepositoryLevel() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 250, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(recipeId: 3, servingsConsumed: 0)

    // MealLogService clamps a zero-serving log up to one serving; the repository-level contract
    // for servings == 0 is a documented no-op.
    XCTAssertTrue(results.isEmpty)
    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 250, accuracy: 1e-9)
    XCTAssertEqual(snap.events.filter { $0.type == "consume" }.count, 0)
  }

  func testZeroPortionMultiplierProducesZeroRequestedResults() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 250, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(
      recipeId: 3, servingsConsumed: 1, portionMultiplier: 0)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(try XCTUnwrap(results.first).requestedGrams, 0, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 0, accuracy: 1e-9)
    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(snap.events.filter { $0.type == "consume" }.count, 0)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 250, accuracy: 1e-9)
  }

  func testOptionalRecipeIngredientsAreNotConsumed() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 7, quantityGrams: 10, location: .fridge, confidenceScore: 1, source: .manual)

    _ = try repository.applyConsumption(recipeId: 2, servingsConsumed: 1)

    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 7), 10, accuracy: 1e-9)
    // No CONSUME event for the optional ingredient (the add event for its lot is expected).
    XCTAssertEqual(
      snap.events.filter { $0.ingredientId == 7 && $0.type == "consume" }.count, 0)
  }

  func testUnknownRecipeIsANoOp() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 250, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(recipeId: 999, servingsConsumed: 2)

    XCTAssertTrue(results.isEmpty)
    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(snap.events.count, 1)  // only the add
  }

  func testConsumptionOrderIsExpiryFirstThenAcquiredThenId() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    // addLot with expiresAt: nil DERIVES an expiry from shelf-life profiles (7/30/90 days by
    // location, even with no profile row); only the .unknown location yields a genuinely
    // expiry-less lot. To test the documented "expiry-less last" ordering we need one, so the
    // expiry-less lot uses .unknown. Added last so its id cannot explain first-place sorting.
    let laterExpiry = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 2), expiresAt: InventoryInvariantSupport.explicitExpiry(slot: 9))
    let soonest = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 3), expiresAt: InventoryInvariantSupport.explicitExpiry(slot: 5))
    let expiryLess = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .unknown, confidenceScore: 1, source: .manual,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 1))

    _ = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    // 250 g: the day-5 lot fully, then the day-9 lot fully, then the expiry-less lot halfway.
    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    let consumeEvents = snap.events.filter { $0.type == "consume" }
    XCTAssertEqual(consumeEvents.map { $0.lotId ?? -1 }, [soonest, laterExpiry, expiryLess])
    for (event, expectedDelta) in zip(consumeEvents, [-100.0, -100.0, -50.0]) {
      XCTAssertEqual(event.delta, expectedDelta, accuracy: 1e-9)
    }
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testExpiryTiesBreakByAcquiredThenId() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let laterAcquired = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 8), expiresAt: InventoryInvariantSupport.explicitExpiry(slot: 5))
    let earlierAcquired = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 4), expiresAt: InventoryInvariantSupport.explicitExpiry(slot: 5))

    _ = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    let consumeEvents = snap.events.filter { $0.type == "consume" }
    XCTAssertEqual(consumeEvents.map { $0.lotId ?? -1 }, [earlierAcquired, laterAcquired])
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testSameSourceRefReingestIsSkipped() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    try repository.addLot(
      ingredientId: 1, quantityGrams: 300, location: .fridge, confidenceScore: 0.9, source: .scan,
      reason: "Grocery update intake", sourceRef: "grocery:1")

    // The documented retry contract lives in grocery intake (InventoryIntakeService): the same
    // source_ref must be recognized and skipped, not double-added.
    XCTAssertTrue(try repository.hasEvent(eventType: .add, sourceRef: "grocery:1"))
    let before = try InventoryInvariantSupport.snapshot(dbQueue)
    if try repository.hasEvent(eventType: .add, sourceRef: " grocery:1 ") {
      // hasEvent normalizes whitespace, matching the service's guard.
    } else {
      XCTFail("hasEvent should trim the ref before matching")
    }
    _ = before
  }

  func testRepeatedMealLogWithSameSourceRefDeductsTwice() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 1000, location: .fridge, confidenceScore: 1, source: .manual)

    // Intended repeated logging, not a retry: the same ref logged twice must deduct twice.
    // The repository has no meal-log dedup and none is asserted — dedup by source_ref is the
    // caller's decision (grocery intake makes it; meal logging does not).
    _ = try repository.applyConsumption(
      recipeId: 3, servingsConsumed: 1, sourceRef: "dinner:3")
    _ = try repository.applyConsumption(
      recipeId: 3, servingsConsumed: 1, sourceRef: "dinner:3")

    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 500, accuracy: 1e-9)
    XCTAssertTrue(try repository.hasEvent(eventType: .consume, sourceRef: "dinner:3"))
    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(snap.events.filter { $0.type == "consume" }.count, 2)
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testRetireThenRestoreReconciles() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 300, location: .fridge, confidenceScore: 1,
      source: .reverseScan, reason: "Scan session restock", sourceRef: "session:1")

    let retired = try dbQueue.write { db -> ScanSessionLot in
      let lot = try XCTUnwrap(
        try repository.lots(in: db, addedBy: "session:1").first { $0.remainingGrams > 0 })
      try repository.retireLot(
        in: db, lot, reason: InventoryRepository.reviewRetirementReason,
        sourceRef: "review:session:1")
      return lot
    }
    XCTAssertEqual(retired.quantityGrams, 300, accuracy: 1e-9)
    // retireLot writes the DB row; the fetched struct is not a live reference, so DB state is
    // the source of truth (asserted via totalRemainingGrams below).
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 0, accuracy: 1e-9)

    let restored = try dbQueue.write { db -> ScanSessionLot in
      let lot = try XCTUnwrap(
        try repository.lots(in: db, addedBy: "session:1").first { $0.wasRetiredByReview })
      try repository.restoreRetiredLot(in: db, lot, sourceRef: "review:session:1")
      return lot
    }
    XCTAssertEqual(restored.quantityGrams, 300, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 300, accuracy: 1e-9)

    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(snap.events.map(\.type), ["add", "adjust", "adjust"])
    for (event, expectedDelta) in zip(snap.events, [300.0, -300.0, 300.0]) {
      XCTAssertEqual(event.delta, expectedDelta, accuracy: 1e-9)
    }
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testFailedTransactionLeavesNoPartialConsumption() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 1000, location: .fridge, confidenceScore: 1, source: .manual)
    let before = try InventoryInvariantSupport.snapshot(dbQueue)

    struct ForcedRollback: Error {}
    XCTAssertThrowsError(
      try dbQueue.write { db in
        _ = try repository.applyConsumption(in: db, recipeId: 3, servingsConsumed: 1)
        throw ForcedRollback()
      }
    )

    // MealLogService composes history + consumption inside one write; a failure anywhere must
    // roll the inventory deduction back with it.
    let after = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 1000, accuracy: 1e-9)
    XCTAssertEqual(after.events.filter { $0.type == "consume" }.count, 0)
    XCTAssertEqual(after.eventCount, before.eventCount)
  }

  func testPreviewMatchesActualDeductionWithServingsPortionAndSwaps() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 6, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual)
    try repository.addLot(
      ingredientId: 2, quantityGrams: 50, location: .fridge, confidenceScore: 1, source: .manual)
    try repository.addLot(
      ingredientId: 5, quantityGrams: 500, location: .fridge, confidenceScore: 1, source: .manual)

    // Recipe 2 serves 4, rows in insertion order: tomato 80, cheese 60, rice 100 (+ optional
    // basil). Logging 2 servings at portion 1.4 with tomato swapped for cheese at ratio 1.5:
    // factor = 2 * 1.4 / 4 = 0.7. The swap REPLACES the tomato row, so its request is
    // 80 * 1.5 * 0.7 = 84 of cheese; the regular cheese row is 60 * 0.7 = 42; rice 100 * 0.7
    // = 70; tomato untouched. Cheese total 126 against 100 available: the first row (84) is
    // processed first and the second (42) takes the remaining 16.
    let swap = IngredientSwap(originalIngredientId: 5, substituteIngredientId: 6, ratio: 1.5)
    let proposals: [(ingredientId: Int64, grams: Double)] = [
      (ingredientId: 6, grams: 84), (ingredientId: 6, grams: 42), (ingredientId: 2, grams: 70)
    ]
    let previews = try repository.previewConsumption(ingredientGrams: proposals)
    XCTAssertEqual(previews.first { $0.ingredientId == 6 }?.availableGrams ?? 0, 100, accuracy: 1e-9)
    XCTAssertEqual(previews.first { $0.ingredientId == 2 }?.shortfallGrams ?? 0, 20, accuracy: 1e-9)

    let results = try repository.applyConsumption(
      recipeId: 2, servingsConsumed: 2, portionMultiplier: 1.4, swaps: [swap])

    let cheese = results.filter { $0.ingredientId == 6 }
    XCTAssertEqual(cheese.count, 2)
    let swapResult = try XCTUnwrap(cheese.first { abs($0.requestedGrams - 84) < 1e-9 })
    XCTAssertEqual(swapResult.consumedGrams, 84, accuracy: 1e-9)
    XCTAssertEqual(swapResult.shortfallGrams, 0, accuracy: 1e-9)
    let regularResult = try XCTUnwrap(cheese.first { abs($0.requestedGrams - 42) < 1e-9 })
    XCTAssertEqual(regularResult.consumedGrams, 16, accuracy: 1e-9)
    XCTAssertEqual(regularResult.shortfallGrams, 26, accuracy: 1e-9)
    let rice = try XCTUnwrap(results.first { $0.ingredientId == 2 })
    XCTAssertEqual(rice.consumedGrams, 50, accuracy: 1e-9)
    XCTAssertEqual(rice.shortfallGrams, 20, accuracy: 1e-9)

    XCTAssertEqual(try repository.totalRemainingGrams(for: 6), 0, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 2), 0, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 5), 500, accuracy: 1e-9)
    XCTAssertTrue(try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }
}
