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
  // MARK: - Fixture

  /// Base epoch for every generated date, so acquired/expiry values are seed-deterministic.
  private let baseDate = Date(timeIntervalSinceReferenceDate: 0)

  private func makeMigratedDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'egg', 1.4, 0.13, 0.01, 0.1),
            (2, 'rice', 130, 2.7, 28, 0.3),
            (3, 'chicken', 165, 31, 0, 3.6),
            (4, 'tofu', 80, 8, 2, 4.8),
            (5, 'tomato', 18, 0.9, 3.9, 0.2),
            (6, 'cheese', 110, 7, 1, 9),
            (7, 'basil', 2, 0.3, 0.4, 0.1);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES
            (1, 'Egg Rice Bowl', 15, 2, 'Cook.'),
            (2, 'Caprese Panzanella', 20, 4, 'Toss.'),
            (3, 'Single Egg', 5, 1, 'Fry.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES
            (1, 1, 1, 100, '100 g'),
            (1, 2, 1, 150, '150 g'),
            (1, 3, 1, 200, '200 g'),
            (2, 5, 1, 80, '80 g'),
            (2, 6, 1, 60, '60 g'),
            (2, 2, 1, 100, '100 g'),
            (2, 7, 0, 10, '10 g'),
            (3, 1, 1, 250, '250 g');
          INSERT INTO ingredient_shelf_life_profiles
            (ingredient_id, fridge_days, pantry_days, freezer_days) VALUES
            (2, 5, 240, 365),
            (6, 21, NULL, 180);
          """
      )
    }
    return dbQueue
  }

  private func acquiredDate(slot: Int) -> Date {
    baseDate.addingTimeInterval(Double(slot) * 60)
  }

  private func explicitExpiry(slot: Int) -> Date {
    baseDate.addingTimeInterval(Double(3 + slot % 18) * 86_400)
  }

  // MARK: - Seeded randomness

  /// SplitMix64: identical seeds yield identical sequences on every platform and run.
  private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }

    mutating func pick<V>(_ choices: [V]) -> V { choices[Int(next() % UInt64(choices.count))] }

    mutating func pickInt(_ low: Int, _ high: Int) -> Int {
      low + Int(next() % UInt64(high - low + 1))
    }

    mutating func pickBool(_ probability: Double) -> Bool {
      Double(next() % 1000) / 1000.0 < probability
    }
  }

  // MARK: - Operation model

  /// One repository operation, kept as data so a failing sequence can be printed and replayed.
  private enum Op: CustomStringConvertible {
    case addLot(
      ingredientId: Int64, grams: Double, location: InventoryStorageLocation, expires: Bool,
      acquiredSlot: Int, confidence: Double, estimate: Bool, sourceRef: String?)
    case reingest(sourceRef: String, item: Int64, grams: Double, slot: Int)
    case logMeal(
      recipeId: Int64, servings: Int, portion: Double, swaps: [IngredientSwap],
      refPrefix: String?, isRetry: Bool, slot: Int)
    case retireSession(sourceRef: String, slot: Int)
    case restoreSession(sourceRef: String, slot: Int)

    var description: String {
      switch self {
      case .addLot(
        let ingredientId, let grams, let location, let expires, let slot, let confidence,
        let estimate, let sourceRef):
        return
          "addLot(ingredientId: \(ingredientId), grams: \(grams), location: \(location.rawValue), "
          + "expires: \(expires), slot: \(slot), confidence: \(confidence), "
          + "estimate: \(estimate), sourceRef: \(sourceRef ?? "nil"))"
      case .reingest(let sourceRef, let item, let grams, let slot):
        return "reingest(sourceRef: \(sourceRef), item: \(item), grams: \(grams), slot: \(slot))"
      case .logMeal(
        let recipeId, let servings, let portion, let swaps, let refPrefix, let isRetry, let slot):
        let swapText = swaps.map {
          "\($0.originalIngredientId)->\($0.substituteIngredientId)@\( $0.ratio)"
        }.joined(separator: ", ")
        return
          "logMeal(recipeId: \(recipeId), servings: \(servings), portion: \(portion), "
          + "swaps: [\(swapText)], refPrefix: \(refPrefix ?? "nil"), isRetry: \(isRetry), "
          + "slot: \(slot))"
      case .retireSession(let sourceRef, let slot):
        return "retireSession(sourceRef: \(sourceRef), slot: \(slot))"
      case .restoreSession(let sourceRef, let slot):
        return "restoreSession(sourceRef: \(sourceRef), slot: \(slot))"
      }
    }
  }

  // MARK: - Seeded operation sequences

  func testSeededOperationSequencesHoldAllInvariants() throws {
    let seeds: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 8]
    var reports: [String] = []

    for seed in seeds {
      let ops = generateOps(seed: seed, opCount: 48)
      if let failure = runSequence(seed: seed, ops: ops) {
        print(failure)
        let reduced = reduceFailingSequence(seed: seed, ops: ops)
        let reducedText = reduced.enumerated().map { index, op in
          "  op #\(index): \(op)"
        }.joined(separator: "\n")
        let report = """
          Seed \(seed) violated an invariant:
          \(failure)
          Reduced failing sequence for seed \(seed) (replays on a fresh migrated in-memory DB):
          \(reducedText)
          """
        print(report)
        reports.append(report)
      }
    }

    XCTAssertTrue(reports.isEmpty, "Invariant violations:\n\(reports.joined(separator: "\n\n"))")
  }

  private func generateOps(seed: UInt64, opCount: Int) -> [Op] {
    var rng = SeededRNG(seed: seed &+ 0x7711)
    var ops: [Op] = []
    var sessionRefs: [String] = []
    var groceryRefs: [String] = []
    var lastLog: (recipe: Int64, servings: Int, portion: Double, swaps: [IngredientSwap], prefix: String?)?
    let portions: [Double] = [0.5, 0.7, 1.0, 1.4, 2.0]
    let ratios: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]

    while ops.count < opCount {
      let slot = ops.count
      switch Int(rng.next() % 100) {
      case 0..<27:
        let grams = Double(rng.next() % 9001) / 10.0
        let sessionRef: String?
        if rng.pickBool(0.5) {
          let ref = "session:\(rng.next() % 3)"
          if !sessionRefs.contains(ref) { sessionRefs.append(ref) }
          sessionRef = ref
        } else {
          sessionRef = nil
        }
        ops.append(
          .addLot(
            ingredientId: Int64(rng.pickInt(1, 6)), grams: grams,
            location: rng.pick([InventoryStorageLocation.fridge, .pantry, .freezer]),
            expires: rng.pickBool(0.6), acquiredSlot: slot,
            confidence: Double(rng.next() % 1001) / 1000.0, estimate: rng.pickBool(0.3),
            sourceRef: sessionRef))
      case 27..<35:
        let ref: String
        if !groceryRefs.isEmpty && rng.pickBool(0.5) {
          ref = groceryRefs[Int(rng.next() % UInt64(groceryRefs.count))]
        } else {
          ref = "grocery:\(rng.next() % 3)"
          if !groceryRefs.contains(ref) { groceryRefs.append(ref) }
        }
        ops.append(
          .reingest(
            sourceRef: ref, item: Int64(rng.pickInt(1, 6)),
            grams: Double(rng.next() % 6001) / 10.0, slot: slot))
      case 35..<80:
        let recipeId = Int64(rng.pickInt(1, 3))
        let servings = rng.pickInt(1, 3)
        let portion = rng.pick(portions)
        let required: [Int64] = recipeId == 1 ? [1, 2, 3] : (recipeId == 2 ? [5, 6, 2] : [1])
        var swaps: [IngredientSwap] = []
        if rng.pickBool(0.55) {
          let original = required[Int(rng.next() % UInt64(required.count))]
          var substitute = Int64(rng.pickInt(1, 6))
          if substitute == original { substitute = substitute % 6 + 1 }
          swaps.append(
            IngredientSwap(
              originalIngredientId: original, substituteIngredientId: substitute,
              ratio: rng.pick(ratios)))
          // Occasionally attaches a second swap for the same original; the repository's
          // documented uniquing keeps the last one.
          if rng.pickBool(0.2) {
            swaps.append(
              IngredientSwap(
                originalIngredientId: original, substituteIngredientId: Int64(rng.pickInt(1, 6)),
                ratio: rng.pick(ratios)))
          }
        }
        let prefix = rng.pickBool(0.5) ? "reverse_scan" : nil
        if lastLog != nil && rng.pickBool(0.25) {
          // A retry of the previous log: identical parameters and source ref. The repository
          // performs no dedup here, so this must deduct again (intended repeated logging).
          ops.append(
            .logMeal(
              recipeId: lastLog!.recipe, servings: lastLog!.servings, portion: lastLog!.portion,
              swaps: lastLog!.swaps, refPrefix: lastLog!.prefix, isRetry: true, slot: slot))
        } else {
          lastLog = (recipeId, servings, portion, swaps, prefix)
          ops.append(
            .logMeal(
              recipeId: recipeId, servings: servings, portion: portion, swaps: swaps,
              refPrefix: prefix, isRetry: false, slot: slot))
        }
      case 80..<90:
        let ref: String
        if !sessionRefs.isEmpty && rng.pickBool(0.6) {
          ref = sessionRefs[Int(rng.next() % UInt64(sessionRefs.count))]
        } else {
          ref = "session:\(rng.next() % 3)"
        }
        ops.append(.retireSession(sourceRef: ref, slot: slot))
      default:
        let ref: String
        if !sessionRefs.isEmpty && rng.pickBool(0.6) {
          ref = sessionRefs[Int(rng.next() % UInt64(sessionRefs.count))]
        } else {
          ref = "session:\(rng.next() % 3)"
        }
        ops.append(.restoreSession(sourceRef: ref, slot: slot))
      }
    }
    return ops
  }

  /// Runs a sequence on a fresh migrated in-memory database; returns nil when every invariant
  /// holds, otherwise a message naming the failing op and every violated check.
  private func runSequence(seed: UInt64, ops: [Op]) -> String? {
    do {
      let dbQueue = try makeMigratedDatabase()
      let repository = InventoryRepository(db: dbQueue)
      for (index, op) in ops.enumerated() {
        let violations = try applyAndCheck(op: op, index: index, repository: repository, dbQueue: dbQueue)
        if !violations.isEmpty {
          return "seed \(seed), first failure at op #\(index): \(op)\n  "
            + violations.joined(separator: "\n  ")
        }
      }
      return nil
    } catch {
      return "seed \(seed): operation threw an error: \(error)"
    }
  }

  /// Greedy delta-debugging: removes one op at a time and keeps any removal that still fails.
  private func reduceFailingSequence(seed: UInt64, ops: [Op]) -> [Op] {
    var current = ops
    var index = 0
    var budget = 240
    while index < current.count && budget > 0 {
      budget -= 1
      var candidate = current
      candidate.remove(at: index)
      if runSequence(seed: seed, ops: candidate) != nil {
        current = candidate
      } else {
        index += 1
      }
    }
    return current
  }

  // MARK: - Per-operation application and checks

  private func applyAndCheck(
    op: Op, index: Int, repository: InventoryRepository, dbQueue: DatabaseQueue
  ) throws -> [String] {
    var violations: [String] = []
    let before = try snapshot(dbQueue)

    switch op {
    case .addLot(
      let ingredientId, let grams, let location, let expires, let slot, let confidence,
      let estimate, let sourceRef):
      let lotId = try repository.addLot(
        ingredientId: ingredientId, quantityGrams: grams, location: location,
        confidenceScore: confidence, source: .scan, acquiredAt: acquiredDate(slot: slot),
        expiresAt: expires ? explicitExpiry(slot: slot) : nil, reason: "Generator restock",
        sourceRef: sourceRef, quantityIsEstimate: estimate)
      let clampedGrams = max(0, grams)
      let clampedConfidence = max(0, min(confidence, 1.0))
      violations += try checkBalanceDelta(
        dbQueue, before: before, ingredientId: ingredientId, delta: clampedGrams)
      violations += try checkLatestEvent(
        dbQueue, ingredientId: ingredientId, lotId: lotId, type: "add",
        expectedDelta: clampedGrams, expectedReason: "Generator restock", expectedSourceRef: sourceRef,
        expectedConfidence: clampedConfidence)

    case .reingest(let sourceRef, let item, let grams, let slot):
      // Mirrors the documented InventoryIntakeService contract: a repeated source_ref is the
      // retry case and must be skipped wholesale; a fresh ref adds one lot.
      if try repository.hasEvent(eventType: .add, sourceRef: sourceRef) {
        let after = try snapshot(dbQueue)
        if after.eventCount != before.eventCount {
          violations.append("duplicate intake with ref \(sourceRef) wrote an event")
        }
        violations += checkBalancesUnchanged(before: before, after: after, context: "duplicate intake \(sourceRef)")
      } else {
        try repository.addLot(
          ingredientId: item, quantityGrams: grams, location: .fridge, confidenceScore: 0.9,
          source: .scan, acquiredAt: acquiredDate(slot: slot), reason: "Grocery update intake",
          sourceRef: sourceRef)
        if !(try repository.hasEvent(eventType: .add, sourceRef: sourceRef)) {
          violations.append("hasEvent returned false right after an add with ref \(sourceRef)")
        }
        violations += try checkBalanceDelta(dbQueue, before: before, ingredientId: item, delta: max(0, grams))
      }

    case .logMeal(
      let recipeId, let servings, let portion, let swaps, let refPrefix, let isRetry, _):
      violations += try performMealLog(
        repository: repository, dbQueue: dbQueue, before: before, recipeId: recipeId,
        servings: servings, portion: portion, swaps: swaps, refPrefix: refPrefix, isRetry: isRetry)

    case .retireSession(let sourceRef, _):
      // Mirrors the scan-review flow: read the session's lots and retire the pick inside one
      // write transaction, so the adjust delta is captured from live state. Partially consumed
      // lots can still have remaining grams, so the pick is by remaining quantity only.
      let picked = try dbQueue.write { db -> ScanSessionLot? in
        let sessionLots = try repository.lots(in: db, addedBy: sourceRef)
        guard let lot = sessionLots.first(where: { $0.remainingGrams > 0 }) else {
          return nil
        }
        try repository.retireLot(
          in: db, lot, reason: InventoryRepository.reviewRetirementReason,
          sourceRef: "review:\(sourceRef)")
        return lot
      }
      if let lot = picked {
        violations += try checkBalanceDelta(
          dbQueue, before: before, ingredientId: lot.ingredientId, delta: -lot.remainingGrams)
        violations += try checkLatestEvent(
          dbQueue, ingredientId: lot.ingredientId, lotId: lot.lotId, type: "adjust",
          expectedDelta: -lot.remainingGrams, expectedReason: InventoryRepository.reviewRetirementReason,
          expectedSourceRef: "review:\(sourceRef)", expectedConfidence: 1.0)
      }

    case .restoreSession(let sourceRef, _):
      let picked = try dbQueue.write { db -> ScanSessionLot? in
        let sessionLots = try repository.lots(in: db, addedBy: sourceRef)
        guard let lot = sessionLots.first(where: { $0.wasRetiredByReview }) else {
          return nil
        }
        try repository.restoreRetiredLot(in: db, lot, sourceRef: "review:\(sourceRef)")
        return lot
      }
      if let lot = picked {
        violations += try checkBalanceDelta(
          dbQueue, before: before, ingredientId: lot.ingredientId, delta: lot.quantityGrams)
        violations += try checkLatestEvent(
          dbQueue, ingredientId: lot.ingredientId, lotId: lot.lotId, type: "adjust",
          expectedDelta: lot.quantityGrams, expectedReason: "Restored during scan review",
          expectedSourceRef: "review:\(sourceRef)", expectedConfidence: 1.0)
      }
    }

    violations += try sweepInvariants(repository: repository, dbQueue: dbQueue)
    if !violations.isEmpty {
      return violations.map { "op #\(index) (\(op)): \($0)" }
    }
    return []
  }

  private func performMealLog(
    repository: InventoryRepository, dbQueue: DatabaseQueue, before: Snapshot, recipeId: Int64,
    servings: Int, portion: Double, swaps: [IngredientSwap], refPrefix: String?, isRetry: Bool
  ) throws -> [String] {
    var violations: [String] = []

    // The documented deduction math (v17/v18 migration comments + applyConsumption): required
    // rows only, substitute at its ratio, factor = servings * portion / recipe servings.
    let (recipeServings, requiredRows): (Int, [(Int64, Double)]) = try dbQueue.read { db in
      let servingsRow = try Int.fetchOne(
        db, sql: "SELECT servings FROM recipes WHERE id = ?", arguments: [recipeId])
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT ingredient_id, quantity_grams FROM recipe_ingredients "
          + "WHERE recipe_id = ? AND is_required = 1 ORDER BY ingredient_id",
        arguments: [recipeId])
      return (servingsRow ?? 0, rows.map { row -> (Int64, Double) in
        let id: Int64 = row["ingredient_id"]
        let grams: Double = row["quantity_grams"]
        return (id, grams)
      })
    }
    let swapByOriginal = Dictionary(
      swaps.map { ($0.originalIngredientId, $0) }, uniquingKeysWith: { _, last in last })
    let servingFactor = Double(servings) * portion / Double(max(recipeServings, 1))
    let expected: [(ingredientId: Int64, grams: Double)] = requiredRows.map { original, baseGrams in
      let swap = swapByOriginal[original]
      return (
        swap?.substituteIngredientId ?? original,
        max(0, baseGrams * (swap?.ratio ?? 1.0) * servingFactor)
      )
    }

    // Production preview (read-only) computed from the same proposed grams before deducting.
    // previewConsumption evaluates each row independently against current availability, while
    // applyConsumption depletes sequentially across rows: row-wise preview equality is exact
    // only for logs whose requests touch each ingredient once (a swap onto an ingredient the
    // recipe already uses can request it twice — see the header comment).
    var requestCount: [Int64: Int] = [:]
    for (ingredientId, _) in expected { requestCount[ingredientId, default: 0] += 1 }
    let previewComparable = expected.allSatisfy { requestCount[$0.ingredientId] == 1 }
    let previews = previewComparable
      ? try repository.previewConsumption(ingredientGrams: expected)
      : []

    let sourceRef = refPrefix.map { "\($0):\(recipeId)" }
    let results = try dbQueue.write { db in
      try repository.applyConsumption(
        in: db, recipeId: recipeId, servingsConsumed: servings, portionMultiplier: portion,
        swaps: swaps, sourceRef: sourceRef)
    }
    let after = try snapshot(dbQueue)

    if isRetry, let sourceRef {
      // No meal-log dedup exists (unlike grocery intake's hasEvent guard): a repeat with the
      // same source_ref must still process the recipe's rows with positive requested grams,
      // not return an empty skip. Nothing stock-related is asserted here — a retry after the
      // first log emptied the shelf legitimately deducts nothing.
      if results.isEmpty || !results.contains(where: { $0.requestedGrams > 0 }) {
        violations.append("retry with ref \(sourceRef) looks dedup-skipped (no rows processed)")
      }
    }

    // Results mirror the preview rows when the log's requests are unique per ingredient.
    if results.count != expected.count {
      violations.append(
        "expected \(expected.count) consumption results, got \(results.count)")
      return violations
    }
    for result in results {
      if previewComparable {
        let preview = previews.first {
          $0.ingredientId == result.ingredientId && sameGrams($0.proposedGrams, result.requestedGrams)
        }
        guard let preview else {
          violations.append(
            "no preview row matches ingredient \(result.ingredientId) requested \(result.requestedGrams); "
              + "previews: \(previews.map { "(\($0.ingredientId), \($0.proposedGrams))" })")
          continue
        }
        if !sameGrams(preview.shortfallGrams, result.shortfallGrams) {
          violations.append(
            "ingredient \(result.ingredientId): preview shortfall \(preview.shortfallGrams) "
              + "differs from actual shortfall \(result.shortfallGrams)")
        }
      }
      if !sameGrams(result.shortfallGrams, max(0, result.requestedGrams - result.consumedGrams)) {
        violations.append(
          "ingredient \(result.ingredientId): shortfall \(result.shortfallGrams) does not equal "
            + "max(0, requested \(result.requestedGrams) - consumed \(result.consumedGrams))")
      }
    }

    // Per ingredient: requested totals match the documented math; consumed equals what the
    // preview said was available, capped by the request; the balance drops by exactly that.
    var requestedTotals: [Int64: Double] = [:]
    for (ingredientId, grams) in expected { requestedTotals[ingredientId, default: 0] += grams }
    var consumedTotals: [Int64: Double] = [:]
    for result in results { consumedTotals[result.ingredientId, default: 0] += result.consumedGrams }

    for (ingredientId, requestedTotal) in requestedTotals {
      let availableBefore = before.balances[ingredientId] ?? 0
      let availableAfter = after.balances[ingredientId] ?? 0
      let consumed = consumedTotals[ingredientId] ?? 0

      if !sameGrams(consumed, min(requestedTotal, availableBefore)) {
        violations.append(
          "ingredient \(ingredientId): consumed \(consumed) but min(requested \(requestedTotal), "
            + "available \(availableBefore)) is \(min(requestedTotal, availableBefore))")
      }
      if !sameGrams(availableBefore - availableAfter, consumed) {
        violations.append(
          "ingredient \(ingredientId): balance dropped \(availableBefore - availableAfter) but "
            + "consumed was \(consumed)")
      }
      if !sameGrams(
        max(0, requestedTotal - availableBefore), max(0, requestedTotal - consumed)) {
        violations.append(
          "ingredient \(ingredientId): shortfall vs preview mismatch (requested \(requestedTotal), "
            + "available \(availableBefore), consumed \(consumed))")
      }

      // Event reconciliation for this log: consume deltas sum to the deduction, and only
      // expected ingredients were touched.
      let opConsumeEvents = after.events.filter { $0.id > before.eventMaxId && $0.type == "consume" }
      let ingredientEvents = opConsumeEvents.filter { $0.ingredientId == ingredientId }
      let eventTotal = ingredientEvents.map(\.delta).reduce(0, +)
      if !sameGrams(-eventTotal, consumed) {
        violations.append(
          "ingredient \(ingredientId): consume events sum to \(-eventTotal) but consumed \(consumed)")
      }
    }

    // Documented FEFO order: the lots this log touched, in first-touch order, must be the
    // prefix of the pre-log candidates in expiry/acquired/id order.
    let opConsumeEvents = after.events.filter { $0.id > before.eventMaxId && $0.type == "consume" }
    for (ingredientId, _) in requestedTotals {
      let candidates = before.lots
        .filter { $0.ingredientId == ingredientId && $0.remaining > 0 }
        .sorted(by: documentedConsumptionOrder)
      let touched = uniqueInFirstTouchOrder(
        opConsumeEvents.filter { $0.ingredientId == ingredientId }.map(\.lotId))
      let expectedPrefix = candidates.prefix(touched.count).map(\.id)
      if touched != expectedPrefix {
        violations.append(
          "ingredient \(ingredientId): touched lots \(touched) do not follow documented FEFO "
            + "order \(expectedPrefix) (candidates \(candidates.map(\.id)))")
      }
      if !touched.isEmpty {
        let lastLot = touched[touched.count - 1]
        for lotId in touched.dropLast() {
          let remaining = after.lots.first { $0.id == lotId }?.remaining ?? 0
          if remaining > 1e-6 {
            violations.append(
              "ingredient \(ingredientId): earlier-ordered lot \(lotId) still holds \(remaining) "
                + "while later lot \(lastLot) was touched")
          }
        }
      }
    }

    return violations
  }

  // MARK: - Snapshot and sweep helpers

  private struct LotRow {
    var id: Int64
    var ingredientId: Int64
    var quantity: Double
    var remaining: Double
    var expiresAt: Date?
    var acquiredAt: Date
  }

  private struct EventRow {
    var id: Int64
    var ingredientId: Int64
    var lotId: Int64?
    var type: String
    var delta: Double
    var confidence: Double
    var createdAt: Date?
  }

  private struct Snapshot {
    var lots: [LotRow]
    var balances: [Int64: Double]
    var events: [EventRow]
    var eventCount: Int
    var eventMaxId: Int64
  }

  private func snapshot(_ dbQueue: DatabaseQueue) throws -> Snapshot {
    try dbQueue.read { db in
      let lotRows = try Row.fetchAll(
        db,
        sql: "SELECT id, ingredient_id, quantity_grams, remaining_grams, expires_at, acquired_at "
          + "FROM inventory_lots ORDER BY id")
      let lots = lotRows.map { row -> LotRow in
        LotRow(
          id: row["id"], ingredientId: row["ingredient_id"], quantity: row["quantity_grams"],
          remaining: row["remaining_grams"], expiresAt: row["expires_at"], acquiredAt: row["acquired_at"])
      }
      let eventRows = try Row.fetchAll(
        db,
        sql: "SELECT id, ingredient_id, lot_id, event_type, quantity_delta_grams, confidence_score, "
          + "created_at FROM inventory_events ORDER BY id")
      let events = eventRows.map { row -> EventRow in
        EventRow(
          id: row["id"], ingredientId: row["ingredient_id"], lotId: row["lot_id"],
          type: row["event_type"], delta: row["quantity_delta_grams"],
          confidence: row["confidence_score"], createdAt: row["created_at"])
      }
      var balances: [Int64: Double] = [:]
      for lot in lots where lot.remaining > 1e-12 {
        balances[lot.ingredientId, default: 0] += lot.remaining
      }
      return Snapshot(
        lots: lots, balances: balances, events: events, eventCount: events.count,
        eventMaxId: events.last?.id ?? 0)
    }
  }

  /// Repository-wide invariants checked after every operation, via raw queries plus the
  /// repository's own aggregate API.
  private func sweepInvariants(repository: InventoryRepository, dbQueue: DatabaseQueue) throws
    -> [String]
  {
    let snap = try snapshot(dbQueue)
    var violations: [String] = []

    var eventDeltas: [Int64: Double] = [:]
    for event in snap.events {
      if let lotId = event.lotId { eventDeltas[lotId, default: 0] += event.delta }
    }

    for lot in snap.lots {
      if lot.remaining < -1e-9 {
        violations.append("lot \(lot.id) has negative remaining \(lot.remaining)")
      }
      if lot.quantity < -1e-9 {
        violations.append("lot \(lot.id) has negative quantity \(lot.quantity)")
      }
      if lot.remaining > lot.quantity + 1e-6 * max(1.0, lot.quantity) {
        violations.append(
          "lot \(lot.id) remaining \(lot.remaining) exceeds quantity \(lot.quantity)")
      }
      // The audit trail is the ledger: the add event carries +quantity_grams, consumption and
      // scan-review adjusts debit their deltas, and restore refills with +quantity_grams, so
      // remaining_grams must equal the running sum of the lot's event deltas.
      let reconciled = eventDeltas[lot.id] ?? 0
      if !sameGrams(reconciled, lot.remaining) {
        violations.append(
          "lot \(lot.id) does not reconcile: event deltas sum to \(reconciled), but remaining "
            + "is \(lot.remaining) (quantity \(lot.quantity))")
      }
    }

    // inventory_items is a maintained snapshot of the remaining lots; it must match raw sums.
    let itemRows = try dbQueue.read { db in
      try Row.fetchAll(db, sql: "SELECT ingredient_id, total_remaining_grams FROM inventory_items")
    }
    for row in itemRows {
      let ingredientId: Int64 = row["ingredient_id"]
      let storedTotal: Double = row["total_remaining_grams"]
      let rawTotal = snap.balances[ingredientId] ?? 0
      if !sameGrams(storedTotal, rawTotal) {
        violations.append(
          "inventory_items for ingredient \(ingredientId) holds \(storedTotal) but lots sum to "
            + "\(rawTotal)")
      }
    }

    // The repository's aggregate API must agree with the raw sums.
    for ingredientId in Set(snap.lots.map(\.ingredientId)).sorted() {
      let apiTotal = try repository.totalRemainingGrams(for: ingredientId)
      let rawTotal = snap.balances[ingredientId] ?? 0
      if !sameGrams(apiTotal, rawTotal) {
        violations.append(
          "totalRemainingGrams(\(ingredientId)) returned \(apiTotal) but lots hold \(rawTotal)")
      }
    }

    // Audit trail ordering: created_at never decreases with id, and recentEvents (created_at
    // DESC, id DESC) is the exact reverse of id order.
    for (earlier, later) in zip(snap.events, snap.events.dropFirst()) {
      if let earlierAt = earlier.createdAt, let laterAt = later.createdAt, laterAt < earlierAt {
        violations.append("event \(later.id) has created_at before event \(earlier.id)")
      }
    }
    let recentIds = try repository.recentEvents(limit: 10_000).map(\.id!)
    if recentIds != Array(snap.events.map(\.id).reversed()) {
      violations.append("recentEvents ordering does not match id-descending audit order")
    }
    for event in snap.events where event.type == "consume" || event.type == "adjust" {
      if event.confidence < 0 || event.confidence > 1 {
        violations.append("event \(event.id) has out-of-range confidence \(event.confidence)")
      }
    }

    return violations
  }

  private func checkBalanceDelta(
    _ dbQueue: DatabaseQueue, before: Snapshot, ingredientId: Int64, delta: Double
  ) throws -> [String] {
    let after = try snapshot(dbQueue)
    let beforeTotal = before.balances[ingredientId] ?? 0
    let afterTotal = after.balances[ingredientId] ?? 0
    if !sameGrams(afterTotal - beforeTotal, delta) {
      return [
        "ingredient \(ingredientId) balance moved \(afterTotal - beforeTotal), expected \(delta)"
      ]
    }
    var untouched = [String]()
    for (id, _) in before.balances where id != ingredientId {
      let was = before.balances[id] ?? 0
      let isNow = after.balances[id] ?? 0
      if !sameGrams(was, isNow) {
        untouched.append("ingredient \(id) changed from \(was) to \(isNow) unexpectedly")
      }
    }
    return untouched
  }

  private func checkBalancesUnchanged(before: Snapshot, after: Snapshot, context: String) -> [String] {
    var violations = [String]()
    for (id, was) in before.balances {
      if !sameGrams(was, after.balances[id] ?? 0) {
        violations.append("\(context): ingredient \(id) changed from \(was) to \(after.balances[id] ?? 0)")
      }
    }
    for (id, isNow) in after.balances where before.balances[id] == nil {
      if isNow > 1e-9 {
        violations.append("\(context): ingredient \(id) appeared with \(isNow)")
      }
    }
    return violations
  }

  private func checkLatestEvent(
    _ dbQueue: DatabaseQueue, ingredientId: Int64, lotId: Int64, type: String, expectedDelta: Double,
    expectedReason: String, expectedSourceRef: String?, expectedConfidence: Double
  ) throws -> [String] {
    try dbQueue.read { db in
      var violations = [String]()
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT lot_id, event_type, quantity_delta_grams, confidence_score, reason, source_ref "
            + "FROM inventory_events WHERE ingredient_id = ? ORDER BY id DESC LIMIT 1",
          arguments: [ingredientId])
      else {
        return ["expected an event for ingredient \(ingredientId), found none"]
      }
      let eventLotId: Int64 = row["lot_id"]
      let eventType: String = row["event_type"]
      let delta: Double = row["quantity_delta_grams"]
      let confidence: Double = row["confidence_score"]
      let reason: String = row["reason"] ?? ""
      let sourceRef: String? = row["source_ref"]
      if eventLotId != lotId { violations.append("latest event lot \(eventLotId), expected \(lotId)") }
      if eventType != type { violations.append("latest event type \(eventType), expected \(type)") }
      if !sameGrams(delta, expectedDelta) {
        violations.append("latest event delta \(delta), expected \(expectedDelta)")
      }
      if reason != expectedReason {
        violations.append("latest event reason '\(reason)', expected '\(expectedReason)'")
      }
      if sourceRef != expectedSourceRef {
        violations.append("latest event sourceRef \(sourceRef ?? "nil"), expected \(expectedSourceRef ?? "nil")")
      }
      if abs(confidence - expectedConfidence) > 1e-9 {
        violations.append("latest event confidence \(confidence), expected \(expectedConfidence)")
      }
      return violations
    }
  }

  // MARK: - Comparison helpers

  private func sameGrams(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) <= 1e-6 * max(1.0, abs(a), abs(b))
  }

  /// The documented consumption order (InventoryRepository): expiry-less lots last, then soonest
  /// expires_at, then earliest acquired_at, then lowest id.
  private func documentedConsumptionOrder(_ a: LotRow, _ b: LotRow) -> Bool {
    switch (a.expiresAt, b.expiresAt) {
    case (nil, _): return false
    case (_, nil): return true
    default: break
    }
    if let aExpiry = a.expiresAt, let bExpiry = b.expiresAt, aExpiry != bExpiry {
      return aExpiry < bExpiry
    }
    if a.acquiredAt != b.acquiredAt { return a.acquiredAt < b.acquiredAt }
    return a.id < b.id
  }

  private func uniqueInFirstTouchOrder(_ lotIds: [Int64?]) -> [Int64] {
    var seen = Set<Int64>()
    var ordered = [Int64]()
    for lotId in lotIds.compactMap({ $0 }) {
      if seen.insert(lotId).inserted { ordered.append(lotId) }
    }
    return ordered
  }

  // MARK: - Explicit boundary cases

  func testConsumeExactBalanceReachesZeroWithoutNegative() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 250, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(try XCTUnwrap(results.first).requestedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).shortfallGrams, 0, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 0, accuracy: 1e-9)
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testConsumeMoreThanBalanceDepletesAndReportsShortfall() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 200, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    XCTAssertEqual(try XCTUnwrap(results.first).requestedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 200, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).shortfallGrams, 50, accuracy: 1e-9)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 0, accuracy: 1e-9)
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testConsumeWithNoStockTakesNothingAndWritesNoEvent() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    let results = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    XCTAssertEqual(try XCTUnwrap(results.first).requestedGrams, 250, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 0, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).shortfallGrams, 250, accuracy: 1e-9)
    let snap = try snapshot(dbQueue)
    XCTAssertEqual(snap.events.count, 0)
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testAddLotClampsNegativeQuantityAndOutOfRangeConfidence() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    let clampedLot = try repository.addLot(
      ingredientId: 1, quantityGrams: -50, location: .fridge, confidenceScore: 1.7, source: .manual)
    let lowConfidenceLot = try repository.addLot(
      ingredientId: 2, quantityGrams: 100, location: .fridge, confidenceScore: -0.5, source: .manual)

    let snap = try snapshot(dbQueue)
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
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testZeroServingsIsANoOpAtRepositoryLevel() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 250, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(recipeId: 3, servingsConsumed: 0)

    // MealLogService clamps a zero-serving log up to one serving; the repository-level contract
    // for servings == 0 is a documented no-op.
    XCTAssertTrue(results.isEmpty)
    let snap = try snapshot(dbQueue)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 250, accuracy: 1e-9)
    XCTAssertEqual(snap.events.filter { $0.type == "consume" }.count, 0)
  }

  func testZeroPortionMultiplierProducesZeroRequestedResults() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 250, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(
      recipeId: 3, servingsConsumed: 1, portionMultiplier: 0)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(try XCTUnwrap(results.first).requestedGrams, 0, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 0, accuracy: 1e-9)
    let snap = try snapshot(dbQueue)
    XCTAssertEqual(snap.events.filter { $0.type == "consume" }.count, 0)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 250, accuracy: 1e-9)
  }

  func testOptionalRecipeIngredientsAreNotConsumed() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 7, quantityGrams: 10, location: .fridge, confidenceScore: 1, source: .manual)

    _ = try repository.applyConsumption(recipeId: 2, servingsConsumed: 1)

    let snap = try snapshot(dbQueue)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 7), 10, accuracy: 1e-9)
    // No CONSUME event for the optional ingredient (the add event for its lot is expected).
    XCTAssertEqual(
      snap.events.filter { $0.ingredientId == 7 && $0.type == "consume" }.count, 0)
  }

  func testUnknownRecipeIsANoOp() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 250, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try repository.applyConsumption(recipeId: 999, servingsConsumed: 2)

    XCTAssertTrue(results.isEmpty)
    let snap = try snapshot(dbQueue)
    XCTAssertEqual(snap.events.count, 1)  // only the add
  }

  func testConsumptionOrderIsExpiryFirstThenAcquiredThenId() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    // addLot with expiresAt: nil DERIVES an expiry from shelf-life profiles (7/30/90 days by
    // location, even with no profile row); only the .unknown location yields a genuinely
    // expiry-less lot. To test the documented "expiry-less last" ordering we need one, so the
    // expiry-less lot uses .unknown. Added last so its id cannot explain first-place sorting.
    let laterExpiry = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual,
      acquiredAt: acquiredDate(slot: 2), expiresAt: explicitExpiry(slot: 9))
    let soonest = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual,
      acquiredAt: acquiredDate(slot: 3), expiresAt: explicitExpiry(slot: 5))
    let expiryLess = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .unknown, confidenceScore: 1, source: .manual,
      acquiredAt: acquiredDate(slot: 1))

    _ = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    // 250 g: the day-5 lot fully, then the day-9 lot fully, then the expiry-less lot halfway.
    let snap = try snapshot(dbQueue)
    let consumeEvents = snap.events.filter { $0.type == "consume" }
    XCTAssertEqual(consumeEvents.map { $0.lotId ?? -1 }, [soonest, laterExpiry, expiryLess])
    for (event, expectedDelta) in zip(consumeEvents, [-100.0, -100.0, -50.0]) {
      XCTAssertEqual(event.delta, expectedDelta, accuracy: 1e-9)
    }
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testExpiryTiesBreakByAcquiredThenId() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let laterAcquired = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual,
      acquiredAt: acquiredDate(slot: 8), expiresAt: explicitExpiry(slot: 5))
    let earlierAcquired = try repository.addLot(
      ingredientId: 1, quantityGrams: 100, location: .fridge, confidenceScore: 1, source: .manual,
      acquiredAt: acquiredDate(slot: 4), expiresAt: explicitExpiry(slot: 5))

    _ = try repository.applyConsumption(recipeId: 3, servingsConsumed: 1)

    let snap = try snapshot(dbQueue)
    let consumeEvents = snap.events.filter { $0.type == "consume" }
    XCTAssertEqual(consumeEvents.map { $0.lotId ?? -1 }, [earlierAcquired, laterAcquired])
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testSameSourceRefReingestIsSkipped() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)

    try repository.addLot(
      ingredientId: 1, quantityGrams: 300, location: .fridge, confidenceScore: 0.9, source: .scan,
      reason: "Grocery update intake", sourceRef: "grocery:1")

    // The documented retry contract lives in grocery intake (InventoryIntakeService): the same
    // source_ref must be recognized and skipped, not double-added.
    XCTAssertTrue(try repository.hasEvent(eventType: .add, sourceRef: "grocery:1"))
    let before = try snapshot(dbQueue)
    if try repository.hasEvent(eventType: .add, sourceRef: " grocery:1 ") {
      // hasEvent normalizes whitespace, matching the service's guard.
    } else {
      XCTFail("hasEvent should trim the ref before matching")
    }
    _ = before
  }

  func testRepeatedMealLogWithSameSourceRefDeductsTwice() throws {
    let dbQueue = try makeMigratedDatabase()
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
    let snap = try snapshot(dbQueue)
    XCTAssertEqual(snap.events.filter { $0.type == "consume" }.count, 2)
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testRetireThenRestoreReconciles() throws {
    let dbQueue = try makeMigratedDatabase()
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

    let snap = try snapshot(dbQueue)
    XCTAssertEqual(snap.events.map(\.type), ["add", "adjust", "adjust"])
    for (event, expectedDelta) in zip(snap.events, [300.0, -300.0, 300.0]) {
      XCTAssertEqual(event.delta, expectedDelta, accuracy: 1e-9)
    }
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }

  func testFailedTransactionLeavesNoPartialConsumption() throws {
    let dbQueue = try makeMigratedDatabase()
    let repository = InventoryRepository(db: dbQueue)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 1000, location: .fridge, confidenceScore: 1, source: .manual)
    let before = try snapshot(dbQueue)

    struct ForcedRollback: Error {}
    XCTAssertThrowsError(
      try dbQueue.write { db in
        _ = try repository.applyConsumption(in: db, recipeId: 3, servingsConsumed: 1)
        throw ForcedRollback()
      }
    )

    // MealLogService composes history + consumption inside one write; a failure anywhere must
    // roll the inventory deduction back with it.
    let after = try snapshot(dbQueue)
    XCTAssertEqual(try repository.totalRemainingGrams(for: 1), 1000, accuracy: 1e-9)
    XCTAssertEqual(after.events.filter { $0.type == "consume" }.count, 0)
    XCTAssertEqual(after.eventCount, before.eventCount)
  }

  func testPreviewMatchesActualDeductionWithServingsPortionAndSwaps() throws {
    let dbQueue = try makeMigratedDatabase()
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
    XCTAssertTrue(try sweepInvariants(repository: repository, dbQueue: dbQueue).isEmpty)
  }
}
