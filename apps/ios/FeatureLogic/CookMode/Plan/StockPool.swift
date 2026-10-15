import Foundation

/// One inventory lot as the allocator sees it. Confidence is deliberately absent: recognition
/// confidence is not quantity confirmation, so the only confirmation signal that reaches the
/// allocator is whether the lot's amount is a photo-intake estimate.
public struct PlanLot: Equatable, Sendable {
  public let ingredientID: Int64
  public let grams: Double
  public let expiresAt: Date?
  /// True when the amount came from photo intake and the user never reviewed it.
  public let quantityIsEstimate: Bool

  public init(ingredientID: Int64, grams: Double, expiresAt: Date?, quantityIsEstimate: Bool) {
    self.ingredientID = ingredientID
    self.grams = grams
    self.expiresAt = expiresAt
    self.quantityIsEstimate = quantityIsEstimate
  }
}

/// The availability pool the allocator reserves from (SPEC.md §7 step 1).
///
/// Built from eligible lots only: fully expired lots leave the pool, quantities already
/// reserved by the previously planned set are subtracted, duplicate lots are summed into one
/// tolerant aggregate per (expiry, estimate) shape, and any unconfirmed (estimate) lot taints
/// the whole ingredient — the pool never claims confirmed stock it cannot prove.
///
/// Value semantics: allocation copies the pool and reserves on its copy, so the caller's pool
/// is never mutated by a plan computation.
public struct StockPool: Equatable, Sendable {
  /// Eligible, coalesced lots for one ingredient, FIFO by expiry (use-soon first; no expiry
  /// last). Ties keep insertion order, so ranking stays deterministic.
  public struct Entry: Equatable, Sendable {
    public let ingredientID: Int64
    public let lots: [PlanLot]
    /// True when any lot of this ingredient is an unconfirmed photo estimate.
    public let containsEstimateLot: Bool
    /// Grams reserved by the already-planned set (subtractive, before this plan).
    public let reservedGrams: Double

    public var totalGrams: Double {
      lots.reduce(0) { $0 + $1.grams }
    }

    public var availableGrams: Double {
      max(0, totalGrams - reservedGrams)
    }

    /// Grams of available stock inside the use-soon horizon.
    public func useSoonGrams(withinHorizonDays horizon: Int, now: Date) -> Double {
      let horizonEnd = now.addingTimeInterval(Double(horizon) * 86_400)
      return lots.reduce(0) { sum, lot in
        guard let expiry = lot.expiresAt, expiry <= horizonEnd else { return sum }
        return sum + lot.grams
      }
    }
  }

  public let now: Date
  public let useSoonHorizonDays: Int
  private var entries: [Int64: Entry]

  /// - Parameters:
  ///   - lots: raw lots from the inventory (duplicates allowed; expired ones are dropped here).
  ///   - reservations: grams per ingredient already reserved by the previously planned set.
  ///   - now: the instant the plan is computed at; expiry is judged against it.
  ///   - useSoonHorizonDays: how close an expiry must be for a lot to count use-soon (×3).
  public init(
    lots: [PlanLot], reservations: [Int64: Double] = [:], now: Date = Date(),
    useSoonHorizonDays: Int = 3
  ) {
    self.now = now
    self.useSoonHorizonDays = useSoonHorizonDays

    var byIngredient: [Int64: [PlanLot]] = [:]
    var estimateFlags: [Int64: Bool] = [:]
    for lot in lots {
      guard lot.grams > 0 else { continue }
      // Fully expired lots leave the pool. Reported as pantry truth elsewhere; never reserved.
      if let expiry = lot.expiresAt, expiry < now { continue }
      byIngredient[lot.ingredientID, default: []].append(lot)
      if lot.quantityIsEstimate {
        estimateFlags[lot.ingredientID] = true
      }
    }

    var built: [Int64: Entry] = [:]
    for (ingredientID, rawLots) in byIngredient {
      // Tolerant aggregate: duplicate lots sharing (expiry, estimate) are summed into one.
      var coalesced: [PlanLot] = []
      var indexByKey: [String: Int] = [:]
      for lot in rawLots {
        let key = "\(lot.expiresAt?.timeIntervalSince1970 ?? .infinity)|\(lot.quantityIsEstimate)"
        if let index = indexByKey[key], let existing = coalesced[safe: index] {
          coalesced[index] = PlanLot(
            ingredientID: lot.ingredientID, grams: existing.grams + lot.grams,
            expiresAt: lot.expiresAt, quantityIsEstimate: lot.quantityIsEstimate)
        } else {
          indexByKey[key] = coalesced.count
          coalesced.append(lot)
        }
      }
      // FIFO by expiry, use-soon first; no expiry last. Ties keep insertion order so ranking
      // stays deterministic (sort is not stable, hence the explicit index tie-break).
      let indexed = coalesced.enumerated().map { ($0.offset, $0.element) }
      let sorted = indexed.sorted { a, b in
        let aKey = a.1.expiresAt ?? .distantFuture
        let bKey = b.1.expiresAt ?? .distantFuture
        if aKey != bKey { return aKey < bKey }
        return a.0 < b.0
      }
      coalesced = sorted.map { $0.1 }
      built[ingredientID] = Entry(
        ingredientID: ingredientID, lots: coalesced,
        containsEstimateLot: estimateFlags[ingredientID] ?? false,
        reservedGrams: reservations[ingredientID] ?? 0)
    }
    self.entries = built
  }

  public func entry(for ingredientID: Int64) -> Entry? {
    entries[ingredientID]
  }

  public func availableGrams(_ ingredientID: Int64) -> Double {
    entries[ingredientID]?.availableGrams ?? 0
  }

  /// True when the ingredient's stock is tainted by an unconfirmed (estimate) lot. A line
  /// covered only by tainted stock is `needs_reconfirming`, never plain `sufficient`.
  public func isEstimateTainted(_ ingredientID: Int64) -> Bool {
    entries[ingredientID]?.containsEstimateLot ?? false
  }

  /// Reserve grams from the pool. Allocation reserves dinner 1's bill before dinner 2 is
  /// chosen, so the same stock can never be counted by two dinners.
  public mutating func reserve(_ ingredientID: Int64, grams: Double) {
    guard let entry = entries[ingredientID] else { return }
    entries[ingredientID] = Entry(
      ingredientID: entry.ingredientID, lots: entry.lots,
      containsEstimateLot: entry.containsEstimateLot,
      reservedGrams: entry.reservedGrams + max(0, grams))
  }

  public static func == (lhs: StockPool, rhs: StockPool) -> Bool {
    lhs.now == rhs.now && lhs.useSoonHorizonDays == rhs.useSoonHorizonDays
      && lhs.entries == rhs.entries
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
