import Foundation
import GRDB
import XCTest

#if canImport(FridgeLuck)
@testable import FridgeLuck
#else
@testable import FLInventoryCore
#endif

/// Mutation tests for the invariant sweep itself.
///
/// `InventoryInvariantSupport.sweepInvariants` guards every operation suite, but a checker that
/// never fires would make those suites' greenness meaningless. Each test here corrupts exactly
/// one invariant class on a FRESH migrated fixture database using raw SQL inside
/// `dbQueue.write` — the kind of damage a buggy writer, a skipped audit event, or a tampered
/// ledger would leave behind — and requires the sweep to come back non-empty with a violation
/// naming the affected lot. Every corruption test also asserts the sweep is clean immediately
/// before the corruption, so a firing sweep is attributable to the corruption and not to the
/// legitimate fixture setup; the pristine control test covers the zero-state false positive.
///
/// Corruption classes covered, one per test:
/// - `remaining_grams` drifted away from its ledger sum (Σ event deltas)
/// - a negative balance on the maintained aggregate snapshot (a lot-level negative is not
///   writable — the schema CHECKs `remaining_grams >= 0` and every writer clamps — so the
///   reachable negative-balance corruption is `inventory_items.total_remaining_grams`, the
///   row the Kitchen reads)
/// - a lot holding more than it started with (the add event accounts for less)
/// - a balance drop with no consume event behind it
/// - an audit event whose delta sign was flipped
/// - a retired lot whose matching adjust event is missing
/// - a refilled (restored) lot whose restore adjust event is missing
final class InventoryInvariantMutationTests: XCTestCase {

  // MARK: - Control

  func testPristineFixtureSweepsClean() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    let violations = try InventoryInvariantSupport.sweepInvariants(
      repository: repository, dbQueue: dbQueue)

    XCTAssertEqual(violations, [], "the pristine migrated fixture must sweep clean (false positive)")
  }

  // MARK: - (a) remaining_grams drifted from the ledger sum

  func testSweepCatchesRemainingGramsDriftFromLedgerSum() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let lotId = try repository.addLot(
      ingredientId: 1, quantityGrams: 1000, location: .fridge, confidenceScore: 1, source: .manual)
    // A legitimate partial consumption puts the ledger at +1000 - 250 for remaining 750.
    _ = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)

    // Drift remaining upward but stay under quantity_grams, so the ledger reconciliation —
    // not the exceeds-quantity or negative checks — is what must catch this.
    try dbQueue.write { db in
      try db.execute(
        sql: "UPDATE inventory_lots SET remaining_grams = remaining_grams + 123.5 WHERE id = ?",
        arguments: [lotId])
    }

    let violations = try InventoryInvariantSupport.sweepInvariants(
      repository: repository, dbQueue: dbQueue)
    assertSweepNamesLot(violations, lotId: lotId, expecting: "does not reconcile")
  }

  // MARK: - (b) negative balance

  func testSweepCatchesNegativeAggregateBalance() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    // addLot creates the ingredient's inventory_items row via refreshInventoryItem.
    _ = try repository.addLot(
      ingredientId: 2, quantityGrams: 800, location: .fridge, confidenceScore: 1, source: .manual)
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)

    // A negative lot-level remaining_grams is un-writable: the schema CHECKs
    // `remaining_grams >= 0` and every repository writer clamps, so the reachable negative
    // balance lives on the maintained snapshot row the Kitchen reads. Pushing it to -50 must
    // trip the sweep's inventory_items-vs-lots reconciliation, which names the ingredient.
    try dbQueue.write { db in
      try db.execute(
        sql: "UPDATE inventory_items SET total_remaining_grams = -50 WHERE ingredient_id = 2")
    }

    let violations = try InventoryInvariantSupport.sweepInvariants(
      repository: repository, dbQueue: dbQueue)
    XCTAssertFalse(
      violations.isEmpty,
      "sweep stayed silent after corrupting ingredient 2's balance to -50", file: #filePath,
      line: #line)
    XCTAssertTrue(
      violations.contains { $0.contains("inventory_items for ingredient 2") && $0.contains("-50") },
      """
      no violation naming ingredient 2's negative inventory_items balance; sweep returned:
      \(violations.joined(separator: "\n"))
      """,
      file: #filePath, line: #line)
  }

  // MARK: - (c) lot above its starting quantity

  func testSweepCatchesLotAboveStartingQuantity() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let lotId = try repository.addLot(
      ingredientId: 3, quantityGrams: 500, location: .fridge, confidenceScore: 1, source: .manual)
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)

    // The lot now holds 600 against quantity_grams 500: the add event says less than the lot
    // holds, so the exceeds-quantity check must fire.
    try dbQueue.write { db in
      try db.execute(
        sql: "UPDATE inventory_lots SET remaining_grams = remaining_grams + 100 WHERE id = ?",
        arguments: [lotId])
    }

    let violations = try InventoryInvariantSupport.sweepInvariants(
      repository: repository, dbQueue: dbQueue)
    assertSweepNamesLot(violations, lotId: lotId, expecting: "exceeds quantity")
  }

  // MARK: - (d) balance drop with no consume event

  func testSweepCatchesBalanceDropWithoutConsumeEvent() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let lotId = try repository.addLot(
      ingredientId: 1, quantityGrams: 1000, location: .fridge, confidenceScore: 1, source: .manual)
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)

    // Stock disappears with no consume event behind it: remaining 800 against ledger +1000.
    try dbQueue.write { db in
      try db.execute(
        sql: "UPDATE inventory_lots SET remaining_grams = remaining_grams - 200 WHERE id = ?",
        arguments: [lotId])
    }

    let violations = try InventoryInvariantSupport.sweepInvariants(
      repository: repository, dbQueue: dbQueue)
    assertSweepNamesLot(violations, lotId: lotId, expecting: "does not reconcile")
  }

  // MARK: - (e) event delta sign flipped

  func testSweepCatchesFlippedEventDeltaSign() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let lotId = try repository.addLot(
      ingredientId: 1, quantityGrams: 1000, location: .fridge, confidenceScore: 1, source: .manual)
    _ = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)  // consume event -250
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)

    // A flipped consume delta (+250) pushes the ledger to +1250 for remaining 750.
    try dbQueue.write { db in
      try db.execute(
        sql: """
          UPDATE inventory_events SET quantity_delta_grams = -quantity_delta_grams
          WHERE event_type = 'consume' AND lot_id = ?
          """,
        arguments: [lotId])
    }

    let violations = try InventoryInvariantSupport.sweepInvariants(
      repository: repository, dbQueue: dbQueue)
    assertSweepNamesLot(violations, lotId: lotId, expecting: "does not reconcile")
  }

  // MARK: - (f) retire without the matching adjust event

  func testSweepCatchesRetirementWithoutAdjustEvent() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let lotId = try repository.addLot(
      ingredientId: 1, quantityGrams: 300, location: .fridge, confidenceScore: 1,
      source: .reverseScan, reason: "Scan session restock", sourceRef: "session:1")
    try dbQueue.write { db in
      let lot = try XCTUnwrap(
        try repository.lots(in: db, addedBy: "session:1").first { $0.remainingGrams > 0 })
      try repository.retireLot(
        in: db, lot, reason: InventoryRepository.reviewRetirementReason,
        sourceRef: "review:session:1")
    }
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)

    // A retirement whose adjust event vanished: remaining 0 against ledger +300. The lot-level
    // and inventory_items totals agree here, so the ledger check is what must catch it.
    try dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM inventory_events WHERE lot_id = ? AND event_type = 'adjust'",
        arguments: [lotId])
    }

    let violations = try InventoryInvariantSupport.sweepInvariants(
      repository: repository, dbQueue: dbQueue)
    assertSweepNamesLot(violations, lotId: lotId, expecting: "does not reconcile")
  }

  // MARK: - (g) restore event missing after a retired lot is refilled

  func testSweepCatchesMissingRestoreEventAfterRefill() throws {
    let dbQueue = try InventoryInvariantSupport.makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let lotId = try repository.addLot(
      ingredientId: 1, quantityGrams: 300, location: .fridge, confidenceScore: 1,
      source: .reverseScan, reason: "Scan session restock", sourceRef: "session:1")
    try dbQueue.write { db in
      let lot = try XCTUnwrap(
        try repository.lots(in: db, addedBy: "session:1").first { $0.remainingGrams > 0 })
      try repository.retireLot(
        in: db, lot, reason: InventoryRepository.reviewRetirementReason,
        sourceRef: "review:session:1")
      let retired = try XCTUnwrap(
        try repository.lots(in: db, addedBy: "session:1").first { $0.wasRetiredByReview })
      try repository.restoreRetiredLot(in: db, retired, sourceRef: "review:session:1")
    }
    XCTAssertTrue(
      try InventoryInvariantSupport.sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)

    // Drop only the restore's positive adjust (the retirement adjust is negative), leaving a
    // refilled lot whose ledger sums to 0 for remaining 300.
    try dbQueue.write { db in
      try db.execute(
        sql: """
          DELETE FROM inventory_events
          WHERE lot_id = ? AND event_type = 'adjust' AND quantity_delta_grams > 0
          """,
        arguments: [lotId])
    }

    let violations = try InventoryInvariantSupport.sweepInvariants(
      repository: repository, dbQueue: dbQueue)
    assertSweepNamesLot(violations, lotId: lotId, expecting: "does not reconcile")
  }

  // MARK: - Helpers

  /// Requires a non-empty sweep with at least one violation naming `lotId` and carrying the
  /// expected check fragment — silence on a known corruption is exactly the bug this suite
  /// exists to surface, and an unattributed firing is not evidence either.
  private func assertSweepNamesLot(
    _ violations: [String], lotId: Int64, expecting fragment: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(
      violations.isEmpty,
      "sweep stayed silent after corrupting lot \(lotId) (expected \"\(fragment)\")",
      file: file, line: line)
    XCTAssertTrue(
      violations.contains { $0.contains("lot \(lotId)") && $0.contains(fragment) },
      """
      no violation naming lot \(lotId) with "\(fragment)"; sweep returned:
      \(violations.joined(separator: "\n"))
      """,
      file: file, line: line)
  }
}
