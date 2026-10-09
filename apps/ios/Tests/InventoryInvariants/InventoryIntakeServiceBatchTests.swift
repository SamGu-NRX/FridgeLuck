import Foundation
import GRDB
import XCTest

#if canImport(FridgeLuck)
@testable import FridgeLuck
#else
@testable import FLInventoryCore
#endif

/// Service-level batch dedup tests for grocery intake, beyond the repository's single-ref
/// `hasEvent` coverage.
///
/// The product contract under test is
/// `InventoryIntakeService.ingestGroceryItems(items: [GroceryIngestItem], sourceRef: String,
/// acquiredAt: Date) throws -> InventoryScanIngestionSummary`
/// (apps/ios/Platform/Persistence/Services/InventoryIntakeService.swift). It deduplicates per
/// submission, not per item:
///
/// - The ref is trimmed, and the dedup key is `hasEvent(eventType: .add, sourceRef:)` — an add
///   event carrying that exact ref.
/// - A submission whose ref was never seen adds EVERY item, including ingredients already
///   stocked under other refs (restocking the same food is normal; only the ref dedups).
/// - A submission whose ref already exists is skipped wholesale: no lots, no events, and the
///   summary reports `skippedAsDuplicate` with zero counts. Meal logging deliberately has no
///   such dedup — the same meal ref logged again deducts again.
///
/// `InventoryIntakeService` itself is not compiled into the `FLInventoryCore` target these
/// Linux tests run against (Package.swift lists that target's sources explicitly and the
/// service is not among them), so each submission drives the repository primitives the real
/// service uses — the real `hasEvent` guard and the real `addLot` with the service's "Grocery
/// update intake" reason — in exactly the service's documented sequence. That is the same
/// mirror `InventoryInvariantSupport` uses for its `.reingest` op. The service's input clamps
/// (a 20 g minimum and confidence clamped to [0.35, 1]) never trigger here because every
/// fixture quantity is at or above 20 g and every confidence is in range; those clamps live in
/// the repository and are pinned elsewhere.
///
/// Everything runs through real GRDB transactions on the migrated in-memory fixture, and the
/// suite-wide invariants (`sweepInvariants`) hold after every step. Dates are fixed, so runs
/// are deterministic.
final class InventoryIntakeServiceBatchTests: XCTestCase {

  // MARK: - Submission fixtures

  /// Mirrors the field shape of `InventoryIntakeService.GroceryIngestItem`.
  private struct BatchItem {
    let ingredientId: Int64
    let quantityGrams: Double
    let storageLocation: InventoryStorageLocation
    var confidenceScore: Double = 0.9
    var source: InventoryLotSource = .scan
  }

  /// Mirrors the skip/accept fields of `InventoryScanIngestionSummary`.
  private struct BatchOutcome {
    var ingredientCount: Int
    var lotsAdded: Int
    var skippedAsDuplicate: Bool
  }

  /// One grocery submission, in the service's documented order: trim the ref, skip wholesale
  /// when an add event already carries it, otherwise add every item with the service's reason
  /// string. (The service's separate no-op branch for an empty ref is out of scope; no test
  /// passes one.)
  private func ingestGroceryBatch(
    _ items: [BatchItem], sourceRef: String, repository: InventoryRepository, acquiredAt: Date
  ) throws -> BatchOutcome {
    let normalizedRef = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
    if try repository.hasEvent(eventType: .add, sourceRef: normalizedRef) {
      return BatchOutcome(ingredientCount: 0, lotsAdded: 0, skippedAsDuplicate: true)
    }
    for item in items {
      _ = try repository.addLot(
        ingredientId: item.ingredientId, quantityGrams: item.quantityGrams,
        location: item.storageLocation, confidenceScore: item.confidenceScore, source: item.source,
        acquiredAt: acquiredAt, reason: "Grocery update intake", sourceRef: normalizedRef)
    }
    return BatchOutcome(
      ingredientCount: items.count, lotsAdded: items.count, skippedAsDuplicate: false)
  }

  // MARK: - Batch dedup contract

  func testMixedBatchAcceptsOnlyFreshSourceRefs() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    // The batch: one settled submission, then a fresh ref mixing a new ingredient with a
    // restock of one already stocked, then two duplicates of existing source_refs.
    let weekOne = try ingestGroceryBatch(
      [
        BatchItem(ingredientId: 2, quantityGrams: 500, storageLocation: .pantry),
        BatchItem(ingredientId: 1, quantityGrams: 300, storageLocation: .fridge),
      ],
      sourceRef: "grocery:week-1", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 0))
    XCTAssertEqual(weekOne.ingredientCount, 2)
    XCTAssertEqual(weekOne.lotsAdded, 2)
    XCTAssertFalse(weekOne.skippedAsDuplicate)

    let weekTwo = try ingestGroceryBatch(
      [
        BatchItem(ingredientId: 3, quantityGrams: 400, storageLocation: .fridge),
        BatchItem(ingredientId: 2, quantityGrams: 250, storageLocation: .pantry),
      ],
      sourceRef: "grocery:week-2", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 1))
    XCTAssertEqual(weekTwo.ingredientCount, 2)
    XCTAssertEqual(weekTwo.lotsAdded, 2)
    XCTAssertFalse(weekTwo.skippedAsDuplicate)

    let weekOneReplay = try ingestGroceryBatch(
      [BatchItem(ingredientId: 4, quantityGrams: 200, storageLocation: .fridge)],
      sourceRef: "grocery:week-1", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 2))
    XCTAssertEqual(weekOneReplay.ingredientCount, 0)
    XCTAssertEqual(weekOneReplay.lotsAdded, 0)
    XCTAssertTrue(weekOneReplay.skippedAsDuplicate)

    let weekTwoWhitespace = try ingestGroceryBatch(
      [BatchItem(ingredientId: 5, quantityGrams: 150, storageLocation: .fridge)],
      sourceRef: "  grocery:week-2  ", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 3))
    XCTAssertEqual(weekTwoWhitespace.ingredientCount, 0)
    XCTAssertEqual(weekTwoWhitespace.lotsAdded, 0)
    XCTAssertTrue(weekTwoWhitespace.skippedAsDuplicate)

    // Only fresh-ref items landed: rice restocked under a new ref (two lots now) and chicken
    // added; the tofu and tomato attached to duplicate refs wrote nothing at all. Dedup keys
    // on the source_ref, never on the ingredient.
    XCTAssertEqual(try repository.totalRemainingGrams(for: 2), 750, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 300, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 3), 400, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 4), 0, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 5), 0, accuracy: 1e-9)
    XCTAssertEqual(try lotCount(dbQueue), 4)
    XCTAssertEqual(try addEventCount(sourceRef: "grocery:week-1", dbQueue: dbQueue), 2)
    XCTAssertEqual(try addEventCount(sourceRef: "grocery:week-2", dbQueue: dbQueue), 2)
    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(snap.events.filter { $0.type == "add" }.count, 4)
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty
    )
  }

  func testReingestingTheSameBatchSkipsEverySubmission() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let items = [
      BatchItem(ingredientId: 2, quantityGrams: 500, storageLocation: .pantry),
      BatchItem(ingredientId: 1, quantityGrams: 300, storageLocation: .fridge),
      BatchItem(ingredientId: 3, quantityGrams: 250, storageLocation: .fridge),
    ]

    let first = try ingestGroceryBatch(
      items, sourceRef: "grocery:week-9", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 0))
    XCTAssertEqual(first.ingredientCount, 3)
    XCTAssertEqual(first.lotsAdded, 3)
    XCTAssertFalse(first.skippedAsDuplicate)

    let before = try InventoryInvariantSupport.snapshot(dbQueue)

    // Retry of the identical submission, then with padding whitespace around the ref: both are
    // the same source_ref after the service's normalization, so both skip wholesale.
    let retry = try ingestGroceryBatch(
      items, sourceRef: "grocery:week-9", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 1))
    XCTAssertEqual(retry.ingredientCount, 0)
    XCTAssertEqual(retry.lotsAdded, 0)
    XCTAssertTrue(retry.skippedAsDuplicate)

    let retryPadded = try ingestGroceryBatch(
      items, sourceRef: "  grocery:week-9  ", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 2))
    XCTAssertEqual(retryPadded.ingredientCount, 0)
    XCTAssertEqual(retryPadded.lotsAdded, 0)
    XCTAssertTrue(retryPadded.skippedAsDuplicate)

    // All skipped: nothing moved and nothing was written.
    let after = try InventoryInvariantSupport.snapshot(dbQueue)
    XCTAssertEqual(after.eventCount, before.eventCount)
    XCTAssertEqual(after.lots.count, before.lots.count)
    XCTAssertTrue(
      InventoryInvariantSupport.checkBalancesUnchanged(
        before: before, after: after, context: "batch replay"
      ).isEmpty)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 2), 500, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 300, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 3), 250, accuracy: 1e-9)
    XCTAssertEqual(try addEventCount(sourceRef: "grocery:week-9", dbQueue: dbQueue), 3)
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty
    )
  }

  func testGroceryIntakeAndMealLoggingInterleaveWithoutLedgerDrift() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    func sweepIsEmpty(_ context: String) throws {
      let violations = try InventoryInvariantSupport.sweepInvariants(
        repository: repository, dbQueue: dbQueue)
      XCTAssertTrue(violations.isEmpty, "\(context): \(violations.joined(separator: "; "))")
    }

    // Week one's eggs arrive.
    let weekOne = try ingestGroceryBatch(
      [BatchItem(ingredientId: 1, quantityGrams: 1000, storageLocation: .fridge)],
      sourceRef: "grocery:eggs:w1", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 0))
    XCTAssertFalse(weekOne.skippedAsDuplicate)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 1000, accuracy: 1e-9)
    try sweepIsEmpty("after week-one intake")

    // Recipe 3 (Single Egg, 250 g/serving) logs twice with the SAME meal ref: meal logging has
    // no dedup, so both logs deduct in full.
    let firstLog = try repository.applyConsumption(
      recipeId: 3, servingsConsumed: 1, sourceRef: "dinner:3")
    XCTAssertEqual(firstLog.count, 1)
    XCTAssertEqual(try XCTUnwrap(firstLog.first).requestedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(firstLog.first).consumedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 750, accuracy: 1e-9)
    try sweepIsEmpty("after first meal log")

    let retryLog = try repository.applyConsumption(
      recipeId: 3, servingsConsumed: 1, sourceRef: "dinner:3")
    XCTAssertEqual(retryLog.count, 1)
    XCTAssertEqual(try XCTUnwrap(retryLog.first).consumedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 500, accuracy: 1e-9)
    try sweepIsEmpty("after repeated meal log")

    // Week two's eggs arrive under a fresh ref, mid-stream.
    let weekTwo = try ingestGroceryBatch(
      [BatchItem(ingredientId: 1, quantityGrams: 600, storageLocation: .fridge)],
      sourceRef: "grocery:eggs:w2", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 1))
    XCTAssertFalse(weekTwo.skippedAsDuplicate)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 1100, accuracy: 1e-9)
    try sweepIsEmpty("after week-two intake")

    // Replaying week one's ref is still an intake duplicate even after meals intervened: dedup
    // keys on the add event, and the meal logs only wrote consume events.
    let weekOneReplay = try ingestGroceryBatch(
      [BatchItem(ingredientId: 1, quantityGrams: 600, storageLocation: .fridge)],
      sourceRef: "grocery:eggs:w1", repository: repository,
      acquiredAt: InventoryInvariantSupport.acquiredDate(slot: 2))
    XCTAssertTrue(weekOneReplay.skippedAsDuplicate)
    XCTAssertEqual(weekOneReplay.lotsAdded, 0)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 1100, accuracy: 1e-9)
    try sweepIsEmpty("after replayed week-one intake")

    // A third log of the same meal ref deducts again.
    let thirdLog = try repository.applyConsumption(
      recipeId: 3, servingsConsumed: 1, sourceRef: "dinner:3")
    XCTAssertEqual(thirdLog.count, 1)
    XCTAssertEqual(try XCTUnwrap(thirdLog.first).consumedGrams, 250, accuracy: 1e-9)
    try sweepIsEmpty("after third meal log")

    // Final ledger: two accepted intakes (+1000, +600), three full meal deductions (-250
    // each), and the replayed intake ref still owns exactly its original add event.
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 850, accuracy: 1e-9)
    XCTAssertTrue(try repository.hasEvent(eventType: .add, sourceRef: "grocery:eggs:w1"))
    XCTAssertTrue(try repository.hasEvent(eventType: .add, sourceRef: "grocery:eggs:w2"))
    XCTAssertTrue(try repository.hasEvent(eventType: .consume, sourceRef: "dinner:3"))
    XCTAssertEqual(try addEventCount(sourceRef: "grocery:eggs:w1", dbQueue: dbQueue), 1)
    let snap = try InventoryInvariantSupport.snapshot(dbQueue)
    let consumeEvents = snap.events.filter { $0.type == "consume" }
    XCTAssertEqual(consumeEvents.count, 3)
    XCTAssertEqual(consumeEvents.map { $0.delta }, [-250, -250, -250])
    try sweepIsEmpty("final ledger")
  }

  // MARK: - Raw ledger probes

  private func lotCount(_ dbQueue: DatabaseQueue) throws -> Int {
    try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inventory_lots") ?? 0
    }
  }

  private func addEventCount(sourceRef: String, dbQueue: DatabaseQueue) throws -> Int {
    try dbQueue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM inventory_events WHERE event_type = 'add' AND source_ref = ?",
        arguments: [sourceRef]) ?? 0
    }
  }
}
