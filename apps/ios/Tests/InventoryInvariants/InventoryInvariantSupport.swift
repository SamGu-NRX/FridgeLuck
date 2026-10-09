import Foundation
import GRDB

#if canImport(FridgeLuck)
@testable import FridgeLuck
#else
@testable import FLInventoryCore
#endif

/// Shared fixture and invariant-checking machinery for the inventory invariant suites.
///
/// Everything here is stateless: the migrated in-memory fixture, the SplitMix64 seeded
/// operation generator and driver, the snapshot/ledger sweep used after every operation, and
/// the comparison helpers. The operation suites in this target all run the same checks through
/// `sweepInvariants`, so a new operation kind or check lands once and protects every suite.
enum InventoryInvariantSupport {
  /// Base epoch for every generated date, so acquired/expiry values are seed-deterministic.
  // MARK: - Fixture

  /// Base epoch for every generated date, so acquired/expiry values are seed-deterministic.
  static let baseDate = Date(timeIntervalSinceReferenceDate: 0)

  static func makeMigratedDatabase() throws -> DatabaseQueue {
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

  static func acquiredDate(slot: Int) -> Date {
    baseDate.addingTimeInterval(Double(slot) * 60)
  }

  static func explicitExpiry(slot: Int) -> Date {
    baseDate.addingTimeInterval(Double(3 + slot % 18) * 86_400)
  }

  // MARK: - Seeded randomness

  /// SplitMix64: identical seeds yield identical sequences on every platform and run.
  struct SeededRNG: RandomNumberGenerator {
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
  enum Op: CustomStringConvertible {
    case addLot(
      ingredientId: Int64, grams: Double, location: InventoryStorageLocation, expires: Bool,
      acquiredSlot: Int, confidence: Double, estimate: Bool, sourceRef: String?)
    case reingest(sourceRef: String, item: Int64, grams: Double, slot: Int)
    case logMeal(
      recipeId: Int64, servings: Int, portion: Double, swaps: [IngredientSwap],
      refPrefix: String?, isRetry: Bool, slot: Int)
    case retireSession(sourceRef: String, slot: Int)
    case restoreSession(sourceRef: String, slot: Int)
    // Composite probe: retire a session lot, then immediately attempt consumption of a recipe
    // requiring the same ingredient — the retired lot must be invisible to the allocator.
    case consumeAfterRetire(sourceRef: String, servings: Int, portion: Double, slot: Int)
    // Composite probe: restore a review-retired lot, then consume the ingredient again — the
    // lot must rejoin the FEFO rotation and the ledger must reconcile.
    case restoreThenReconsume(sourceRef: String, servings: Int, portion: Double, slot: Int)
    // Composite probe: two scan sessions restock the same ingredient with meal logs
    // interleaved between and after the adds.
    case sessionInterleave(
      ingredientId: Int64, gramsA: Double, gramsB: Double, servings: Int, portion: Double,
      slot: Int)
    // Composite probe: adds sized to exactly the recipe's request, then one consumption —
    // every shelf must land on exactly zero.
    case consumeExactTotalAfterAdds(recipeId: Int64, servings: Int, portion: Double, slot: Int)

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
      case .consumeAfterRetire(let sourceRef, let servings, let portion, let slot):
        return
          "consumeAfterRetire(sourceRef: \(sourceRef), servings: \(servings), portion: \(portion), "
          + "slot: \(slot))"
      case .restoreThenReconsume(let sourceRef, let servings, let portion, let slot):
        return
          "restoreThenReconsume(sourceRef: \(sourceRef), servings: \(servings), portion: \(portion), "
          + "slot: \(slot))"
      case .sessionInterleave(let ingredientId, let gramsA, let gramsB, let servings, let portion, let slot):
        return
          "sessionInterleave(ingredientId: \(ingredientId), gramsA: \(gramsA), gramsB: \(gramsB), "
          + "servings: \(servings), portion: \(portion), slot: \(slot))"
      case .consumeExactTotalAfterAdds(let recipeId, let servings, let portion, let slot):
        return
          "consumeExactTotalAfterAdds(recipeId: \(recipeId), servings: \(servings), "
          + "portion: \(portion), slot: \(slot))"
      }
    }
  }
  static func generateOps(seed: UInt64, opCount: Int) -> [Op] {
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
      case 0..<25:
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
      case 25..<33:
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
      case 33..<70:
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
      case 70..<78:
        let ref: String
        if !sessionRefs.isEmpty && rng.pickBool(0.6) {
          ref = sessionRefs[Int(rng.next() % UInt64(sessionRefs.count))]
        } else {
          ref = "session:\(rng.next() % 3)"
        }
        ops.append(.retireSession(sourceRef: ref, slot: slot))
      case 78..<86:
        let ref: String
        if !sessionRefs.isEmpty && rng.pickBool(0.6) {
          ref = sessionRefs[Int(rng.next() % UInt64(sessionRefs.count))]
        } else {
          ref = "session:\(rng.next() % 3)"
        }
        ops.append(.restoreSession(sourceRef: ref, slot: slot))
      case 86..<90:
        // Retire a session lot, then immediately attempt consumption of the same ingredient.
        let ref: String
        if !sessionRefs.isEmpty && rng.pickBool(0.6) {
          ref = sessionRefs[Int(rng.next() % UInt64(sessionRefs.count))]
        } else {
          ref = "session:\(rng.next() % 3)"
        }
        ops.append(
          .consumeAfterRetire(
            sourceRef: ref, servings: rng.pickInt(1, 3), portion: rng.pick(portions), slot: slot))
      case 90..<94:
        // Restore a review-retired lot, then consume the ingredient again.
        let ref: String
        if !sessionRefs.isEmpty && rng.pickBool(0.6) {
          ref = sessionRefs[Int(rng.next() % UInt64(sessionRefs.count))]
        } else {
          ref = "session:\(rng.next() % 3)"
        }
        ops.append(
          .restoreThenReconsume(
            sourceRef: ref, servings: rng.pickInt(1, 3), portion: rng.pick(portions), slot: slot))
      case 94..<97:
        // Two sessions restock one ingredient around meal logs; only ingredients some recipe
        // requires are eligible, so the interleaved consumption always runs.
        ops.append(
          .sessionInterleave(
            ingredientId: rng.pick([Int64(1), 2, 3, 5, 6]),
            gramsA: Double(rng.next() % 4001) / 10.0, gramsB: Double(rng.next() % 4001) / 10.0,
            servings: rng.pickInt(1, 3), portion: rng.pick(portions), slot: slot))
      default:
        // Adds sized to exactly the recipe request, then a single consumption.
        ops.append(
          .consumeExactTotalAfterAdds(
            recipeId: Int64(rng.pickInt(1, 3)), servings: rng.pickInt(1, 3),
            portion: rng.pick(portions), slot: slot))
      }
    }
    return ops
  }

  /// Generates, runs, and (on failure) reduces one seeded operation sequence against a fresh
  /// migrated in-memory database. Returns a formatted failure report, or nil when every
  /// invariant held. Deterministic: the same seed and op count always produce the same
  /// operations, the same verdict, and the same reduced sequence.
  static func runSeededFuzz(seed: UInt64, opCount: Int) -> String? {
    let ops = generateOps(seed: seed, opCount: opCount)
    guard let failure = runSequence(seed: seed, ops: ops) else { return nil }
    print(failure)
    let reduced = reduceFailingSequence(seed: seed, ops: ops)
    let reducedText = reduced.enumerated().map { index, op in
      "  op #\(index): \(op)"
    }.joined(separator: "\n")
    return """
      Seed \(seed) violated an invariant:
      \(failure)
      Reduced failing sequence for seed \(seed) (replays on a fresh migrated in-memory DB):
      \(reducedText)
      """
  }

  /// Runs a sequence on a fresh migrated in-memory database; returns nil when every invariant
  /// holds, otherwise a message naming the failing op and every violated check.
  static func runSequence(seed: UInt64, ops: [Op]) -> String? {
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
  static func reduceFailingSequence(seed: UInt64, ops: [Op]) -> [Op] {
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

  static func applyAndCheck(
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

    case .consumeAfterRetire(let sourceRef, let servings, let portion, _):
      // Scan review retires a lot, then a cook immediately attempts consumption of a recipe
      // requiring the same ingredient. The retired lot is invisible to the allocator: it must
      // never show up in a consume event, and when it was the ingredient's last stock the
      // attempt deducts zero and writes no consume event at all.
      let retired = try dbQueue.write { db -> ScanSessionLot? in
        let sessionLots = try repository.lots(in: db, addedBy: sourceRef)
        guard let lot = sessionLots.first(where: { $0.remainingGrams > 0 }) else {
          return nil
        }
        try repository.retireLot(
          in: db, lot, reason: InventoryRepository.reviewRetirementReason,
          sourceRef: "review:\(sourceRef)")
        return lot
      }
      guard let lot = retired else { break }
      violations += try checkBalanceDelta(
        dbQueue, before: before, ingredientId: lot.ingredientId, delta: -lot.remainingGrams)
      violations += try checkLatestEvent(
        dbQueue, ingredientId: lot.ingredientId, lotId: lot.lotId, type: "adjust",
        expectedDelta: -lot.remainingGrams,
        expectedReason: InventoryRepository.reviewRetirementReason,
        expectedSourceRef: "review:\(sourceRef)", expectedConfidence: 1.0)
      guard let recipeId = try recipeRequiring(dbQueue, lot.ingredientId) else { break }
      let beforeConsume = try snapshot(dbQueue)
      violations += try performMealLog(
        repository: repository, dbQueue: dbQueue, before: beforeConsume, recipeId: recipeId,
        servings: servings, portion: portion, swaps: [], refPrefix: nil, isRetry: false)
      let afterConsume = try snapshot(dbQueue)
      let newConsumeEvents = afterConsume.events.filter {
        $0.id > beforeConsume.eventMaxId && $0.type == "consume"
      }
      if newConsumeEvents.contains(where: { $0.lotId == lot.lotId }) {
        violations.append("retired lot \(lot.lotId) was consumed after retirement")
      }
      if (beforeConsume.balances[lot.ingredientId] ?? 0) < 1e-9 {
        // The retired lot was the ingredient's last stock.
        if !sameGrams(afterConsume.balances[lot.ingredientId] ?? 0, 0) {
          violations.append(
            "ingredient \(lot.ingredientId) moved to \(afterConsume.balances[lot.ingredientId] ?? 0)"
              + " by a consumption attempt against an empty shelf")
        }
        if newConsumeEvents.contains(where: { $0.ingredientId == lot.ingredientId }) {
          violations.append(
            "consume event written for ingredient \(lot.ingredientId) with nothing in stock")
        }
      }

    case .restoreThenReconsume(let sourceRef, let servings, let portion, _):
      // Scan review restores a retired lot, then a cook consumes the ingredient again: the
      // lot must rejoin the FEFO rotation at its full quantity and the ledger must reconcile
      // across the restore and the new consumption (meal-log identities plus the sweep).
      let restored = try dbQueue.write { db -> ScanSessionLot? in
        let sessionLots = try repository.lots(in: db, addedBy: sourceRef)
        guard let lot = sessionLots.first(where: { $0.wasRetiredByReview }) else {
          return nil
        }
        try repository.restoreRetiredLot(in: db, lot, sourceRef: "review:\(sourceRef)")
        return lot
      }
      guard let lot = restored else { break }
      violations += try checkBalanceDelta(
        dbQueue, before: before, ingredientId: lot.ingredientId, delta: lot.quantityGrams)
      violations += try checkLatestEvent(
        dbQueue, ingredientId: lot.ingredientId, lotId: lot.lotId, type: "adjust",
        expectedDelta: lot.quantityGrams, expectedReason: "Restored during scan review",
        expectedSourceRef: "review:\(sourceRef)", expectedConfidence: 1.0)
      guard let recipeId = try recipeRequiring(dbQueue, lot.ingredientId) else { break }
      violations += try performMealLog(
        repository: repository, dbQueue: dbQueue, before: try snapshot(dbQueue),
        recipeId: recipeId, servings: servings, portion: portion, swaps: [], refPrefix: nil,
        isRetry: false)

    case .sessionInterleave(
      let ingredientId, let gramsA, let gramsB, let servings, let portion, let slot):
      // Two scan sessions restock the same ingredient with a meal log interleaved between the
      // adds and another after the second: FEFO must span lots from different sessions and the
      // ledger must reconcile across all four writes. Session B acquires later with a later
      // explicit expiry, so A's lot always sorts first once both are in play.
      let refA = "session:interleave:\(slot):a"
      let refB = "session:interleave:\(slot):b"
      guard let recipeId = try recipeRequiring(dbQueue, ingredientId) else { break }
      let beforeA = try snapshot(dbQueue)
      let lotA = try repository.addLot(
        ingredientId: ingredientId, quantityGrams: gramsA, location: .fridge, confidenceScore: 0.9,
        source: .scan, acquiredAt: acquiredDate(slot: slot), expiresAt: explicitExpiry(slot: slot),
        reason: "Scan session restock", sourceRef: refA)
      violations += try checkBalanceDelta(
        dbQueue, before: beforeA, ingredientId: ingredientId, delta: gramsA)
      violations += try checkLatestEvent(
        dbQueue, ingredientId: ingredientId, lotId: lotA, type: "add", expectedDelta: gramsA,
        expectedReason: "Scan session restock", expectedSourceRef: refA, expectedConfidence: 0.9)
      violations += try performMealLog(
        repository: repository, dbQueue: dbQueue, before: try snapshot(dbQueue),
        recipeId: recipeId, servings: servings, portion: portion, swaps: [], refPrefix: nil,
        isRetry: false)
      let beforeB = try snapshot(dbQueue)
      let lotB = try repository.addLot(
        ingredientId: ingredientId, quantityGrams: gramsB, location: .fridge, confidenceScore: 0.9,
        source: .scan, acquiredAt: acquiredDate(slot: slot + 1),
        expiresAt: explicitExpiry(slot: slot + 7), reason: "Scan session restock", sourceRef: refB)
      violations += try checkBalanceDelta(
        dbQueue, before: beforeB, ingredientId: ingredientId, delta: gramsB)
      violations += try checkLatestEvent(
        dbQueue, ingredientId: ingredientId, lotId: lotB, type: "add", expectedDelta: gramsB,
        expectedReason: "Scan session restock", expectedSourceRef: refB, expectedConfidence: 0.9)
      violations += try performMealLog(
        repository: repository, dbQueue: dbQueue, before: try snapshot(dbQueue),
        recipeId: recipeId, servings: servings, portion: portion, swaps: [], refPrefix: nil,
        isRetry: false)

    case .consumeExactTotalAfterAdds(let recipeId, let servings, let portion, let slot):
      // Empties every required shelf the audited way first — scan-review retirement of each
      // live lot — then adds two lots per required ingredient sized so their sum is exactly
      // the recipe's request at this factor, then consumes once: every added lot must drain
      // completely and every required shelf must land on exactly zero.
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
      let servingFactor = Double(servings) * portion / Double(max(recipeServings, 1))
      var requiredTotals: [Int64: Double] = [:]
      for (ingredientId, baseGrams) in requiredRows {
        requiredTotals[ingredientId, default: 0] += baseGrams * servingFactor
      }
      var addedLotIds: [Int64] = []
      for (ingredientId, total) in requiredTotals.sorted(by: { $0.key < $1.key }) {
        // Clear the shelf through the repository (scan-review retirement of every live lot),
        // so the exact-total adds are the only stock the consumption can draw from.
        let beforeRetire = try snapshot(dbQueue)
        try dbQueue.write { db in
          let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, quantity_grams, remaining_grams FROM inventory_lots "
              + "WHERE ingredient_id = ? AND remaining_grams > 0",
            arguments: [ingredientId])
          for row in rows {
            let id: Int64 = row["id"]
            let quantity: Double = row["quantity_grams"]
            let remaining: Double = row["remaining_grams"]
            try repository.retireLot(
              in: db,
              ScanSessionLot(
                lotId: id, ingredientId: ingredientId, quantityGrams: quantity,
                remainingGrams: remaining, wasConsumed: false, wasRetiredByReview: false),
              reason: InventoryRepository.reviewRetirementReason,
              sourceRef: "review:exact:\(slot):\(ingredientId)")
          }
        }
        violations += try checkBalanceDelta(
          dbQueue, before: beforeRetire, ingredientId: ingredientId,
          delta: -(beforeRetire.balances[ingredientId] ?? 0))
        for share in [0.4, 0.6] {
          let beforeAdd = try snapshot(dbQueue)
          let lotId = try repository.addLot(
            ingredientId: ingredientId, quantityGrams: total * share, location: .fridge,
            confidenceScore: 0.9, source: .scan, acquiredAt: acquiredDate(slot: slot),
            expiresAt: explicitExpiry(slot: slot), reason: "Exact-total restock")
          addedLotIds.append(lotId)
          violations += try checkBalanceDelta(
            dbQueue, before: beforeAdd, ingredientId: ingredientId, delta: total * share)
          violations += try checkLatestEvent(
            dbQueue, ingredientId: ingredientId, lotId: lotId, type: "add",
            expectedDelta: total * share, expectedReason: "Exact-total restock",
            expectedSourceRef: nil, expectedConfidence: 0.9)
        }
      }
      violations += try performMealLog(
        repository: repository, dbQueue: dbQueue, before: try snapshot(dbQueue),
        recipeId: recipeId, servings: servings, portion: portion, swaps: [], refPrefix: nil,
        isRetry: false)
      let afterConsume = try snapshot(dbQueue)
      for (ingredientId, total) in requiredTotals {
        let remaining = afterConsume.balances[ingredientId] ?? 0
        if !sameGrams(remaining, 0) {
          violations.append(
            "ingredient \(ingredientId) holds \(remaining) after consuming exactly the added "
              + "\(total)")
        }
      }
      for lotId in addedLotIds {
        guard let lot = afterConsume.lots.first(where: { $0.id == lotId }) else {
          violations.append("added lot \(lotId) disappeared from inventory_lots")
          continue
        }
        if !sameGrams(lot.remaining, 0) {
          violations.append(
            "added lot \(lotId) holds \(lot.remaining) after an exact-total consumption")
        }
      }
    }

    violations += try sweepInvariants(repository: repository, dbQueue: dbQueue)
    if !violations.isEmpty {
      return violations.map { "op #\(index) (\(op)): \($0)" }
    }
    return []
  }

  /// The lowest-id recipe with a required row for the ingredient, from the migrated fixture;
  /// nil when the ingredient only ever appears as an optional row (basil).
  static func recipeRequiring(_ dbQueue: DatabaseQueue, _ ingredientId: Int64) throws -> Int64? {
    try dbQueue.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT recipe_id FROM recipe_ingredients WHERE ingredient_id = ? AND is_required = 1 "
          + "ORDER BY recipe_id LIMIT 1",
        arguments: [ingredientId])
    }
  }

  static func performMealLog(
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

  struct LotRow {
    var id: Int64
    var ingredientId: Int64
    var quantity: Double
    var remaining: Double
    var expiresAt: Date?
    var acquiredAt: Date
  }

  struct EventRow {
    var id: Int64
    var ingredientId: Int64
    var lotId: Int64?
    var type: String
    var delta: Double
    var confidence: Double
    var createdAt: Date?
  }

  struct Snapshot {
    var lots: [LotRow]
    var balances: [Int64: Double]
    var events: [EventRow]
    var eventCount: Int
    var eventMaxId: Int64
  }

  static func snapshot(_ dbQueue: DatabaseQueue) throws -> Snapshot {
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
  static func sweepInvariants(repository: InventoryRepository, dbQueue: DatabaseQueue) throws
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

  static func checkBalanceDelta(
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

  static func checkBalancesUnchanged(before: Snapshot, after: Snapshot, context: String) -> [String] {
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

  static func checkLatestEvent(
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

  static func sameGrams(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) <= 1e-6 * max(1.0, abs(a), abs(b))
  }

  /// The documented consumption order (InventoryRepository): expiry-less lots last, then soonest
  /// expires_at, then earliest acquired_at, then lowest id.
  static func documentedConsumptionOrder(_ a: LotRow, _ b: LotRow) -> Bool {
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

  static func uniqueInFirstTouchOrder(_ lotIds: [Int64?]) -> [Int64] {
    var seen = Set<Int64>()
    var ordered = [Int64]()
    for lotId in lotIds.compactMap({ $0 }) {
      if seen.insert(lotId).inserted { ordered.append(lotId) }
    }
    return ordered
  }
}
