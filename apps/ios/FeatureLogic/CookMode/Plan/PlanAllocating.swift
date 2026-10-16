import Foundation

/// A recipe the allocator may choose, with its ingredient bill for the recipe's base servings.
/// Lines are per-ingredient (duplicates already summed) but the allocator sums again defensively,
/// so the no-double-counting guarantee never depends on the adapter.
public struct PlanCandidateLine: Equatable, Sendable {
  public let ingredientID: Int64
  public let name: String
  /// Grams for the recipe's base servings. `<= 0` means the quantity is unknown ("to taste").
  public let grams: Double
  public let isRequired: Bool

  public init(ingredientID: Int64, name: String, grams: Double, isRequired: Bool) {
    self.ingredientID = ingredientID
    self.name = name
    self.grams = grams
    self.isRequired = isRequired
  }
}

public struct PlanCandidate: Equatable, Sendable {
  public let databaseID: Int64
  public let ref: RecipeRef
  public let title: String
  public let timeMinutes: Int?
  public let baseServings: Int
  public let lines: [PlanCandidateLine]

  public init(
    databaseID: Int64, ref: RecipeRef, title: String, timeMinutes: Int?, baseServings: Int,
    lines: [PlanCandidateLine]
  ) {
    self.databaseID = databaseID
    self.ref = ref
    self.title = title
    self.timeMinutes = timeMinutes
    self.baseServings = baseServings
    self.lines = lines
  }
}

/// One eater whose restrictions are a hard filter (PR #86 §3.3). A recipe with a required line
/// on a blocked ingredient is never suggested, even when waiving it would score higher.
public struct PlanEater: Equatable, Sendable {
  public let id: String
  public let blockedIngredientIDs: Set<Int64>

  public init(id: String, blockedIngredientIDs: Set<Int64>) {
    self.id = id
    self.blockedIngredientIDs = blockedIngredientIDs
  }
}

/// A reviewed substitution the allocator may apply when the original is short.
/// `substituteGramsPerOriginalGram` converts original grams to substitute grams.
public struct PlanSubstitution: Equatable, Sendable {
  public let originalID: Int64
  public let substituteID: Int64
  public let substituteGramsPerOriginalGram: Double
  public let note: String?
  public let reviewed: Bool

  public init(
    originalID: Int64, substituteID: Int64, substituteGramsPerOriginalGram: Double, note: String?,
    reviewed: Bool
  ) {
    self.originalID = originalID
    self.substituteID = substituteID
    self.substituteGramsPerOriginalGram = substituteGramsPerOriginalGram
    self.note = note
    self.reviewed = reviewed
  }
}

/// Weekly-horizon rules (SPEC.md §14, draft #52 marked "Adapt": the same allocator core across
/// seven slots with a repeat penalty and leftover carry — not a second planner).
///
/// `nil` (the default on `PlanRequest`) keeps the three-dinner behavior exactly: a chosen recipe
/// is excluded outright and no surplus is carried. With a policy set, repeats become rankable but
/// penalized (#52's "extra uses of a recipe beyond its first" term), the same main ingredient two
/// days in a row is penalized, and a dinner's surplus servings cover a later slot that reserves
/// nothing new.
public struct PlanWeeklyPolicy: Equatable, Sendable {
  /// Servings the household eats per dinner. A dinner cooked for more servings than this leaves
  /// surplus; a later slot whose pending surplus covers a full round of eaters becomes a
  /// leftovers night — the earlier dinner's dish again, no new reservations. `nil` disables
  /// leftover carry.
  public var eatersPerDinner: Int?
  /// Ranking penalty, in grams of coverage-equivalent, subtracted when the candidate was already
  /// chosen for an earlier slot of this plan.
  public var repeatPenalty: Double
  /// Ranking penalty, in grams of coverage-equivalent, subtracted when the candidate's main
  /// ingredient (its largest required line) is the main ingredient of the immediately preceding
  /// slot — the same main two days in a row.
  public var consecutiveMainIngredientPenalty: Double

  public init(
    eatersPerDinner: Int? = nil, repeatPenalty: Double = 0,
    consecutiveMainIngredientPenalty: Double = 0
  ) {
    self.eatersPerDinner = eatersPerDinner
    self.repeatPenalty = max(0, repeatPenalty)
    self.consecutiveMainIngredientPenalty = max(0, consecutiveMainIngredientPenalty)
  }
}

/// Everything one deterministic allocation run needs.
public struct PlanRequest: Equatable, Sendable {
  public var dinnerCount: Int
  /// Servings per dinner position; falls back to the last entry when shorter.
  public var servingsPerDinner: [Int]
  public var candidates: [PlanCandidate]
  public var eaters: [PlanEater]
  public var substitutions: [PlanSubstitution]
  /// Ingredients the household marks as always/usually on hand (staple tiers).
  public var stapleIngredientIDs: Set<Int64>
  public var pool: StockPool
  /// Recipe database IDs to skip (regenerate, replace-one-dinner, already-planned set).
  public var excludeDatabaseIDs: Set<Int64>
  /// Weekly-horizon rules; `nil` is the three-dinner default.
  public var weekly: PlanWeeklyPolicy?
  public var planID: String
  public var createdAt: Date

  public init(
    dinnerCount: Int, servingsPerDinner: [Int] = [], candidates: [PlanCandidate],
    eaters: [PlanEater] = [], substitutions: [PlanSubstitution] = [],
    stapleIngredientIDs: Set<Int64> = [], pool: StockPool, excludeDatabaseIDs: Set<Int64> = [],
    weekly: PlanWeeklyPolicy? = nil, planID: String, createdAt: Date
  ) {
    self.dinnerCount = dinnerCount
    self.servingsPerDinner = servingsPerDinner
    self.candidates = candidates
    self.eaters = eaters
    self.substitutions = substitutions
    self.stapleIngredientIDs = stapleIngredientIDs
    self.pool = pool
    self.excludeDatabaseIDs = excludeDatabaseIDs
    self.weekly = weekly
    self.planID = planID
    self.createdAt = createdAt
  }

  public func servings(forPosition position: Int) -> Int {
    // position is 1-based; clamp to something sane.
    if let value = servingsPerDinner[safe: position - 1], value >= 1 { return value }
    if let last = servingsPerDinner.last, last >= 1 { return last }
    return 2
  }
}

/// The deterministic dinner-plan allocator (SPEC.md §7).
///
/// Contract: pure, local, <100 ms; same inputs → same output. Use-soon lots go first (their
/// coverage counts triple in scoring; reservation walks lots FIFO by expiry). Reserved quantities
/// are removed from the pool before the next dinner is chosen, so no stock is ever counted by two
/// dinners, two lines, or a swap and its original.
public enum PlanAllocating {
  /// A dinner still ships with at most this many short required lines; beyond that it is not
  /// selectable (SPEC.md §7 step 4).
  static let maxShortRequiredLines = 2

  /// Allocate `request.dinnerCount` dinners from the pool and merge the shortfall into one
  /// shopping list. Returns a plan with an empty `dinners` array when nothing is feasible.
  public static func allocate(_ request: PlanRequest) -> LeChefPlan {
    var pool = request.pool
    let blockedUnion = request.eaters.reduce(into: Set<Int64>()) { result, eater in
      result.formUnion(eater.blockedIngredientIDs)
    }
    // Pre-merge duplicate lines per candidate so demand can never be counted twice.
    let eligible = request.candidates
      .filter { !request.excludeDatabaseIDs.contains($0.databaseID) }
      .filter { candidate in restrictionClean(candidate, blockedUnion: blockedUnion) }
      .map(mergedLines)

    var dinners: [PlannedDinner] = []
    var chosen: Set<Int64> = []
    var pendingLeftoverServings = 0
    var lastMainIngredientID: Int64?
    var lastCooked: (
      dinnerID: String, ref: RecipeRef, databaseID: Int64, title: String, timeMinutes: Int?
    )?
    var shopping: [Int64: (grams: Double, stapleGrams: Double, name: String)] = [:]
    var sufficientLines = 0
    var totalLines = 0
    var swapCount = 0
    var attention: [String] = []

    // A recipe's main ingredient (its largest required line) drives the consecutive-main
    // penalty in weekly mode.
    let mainIngredientByCandidate: [Int64: Int64] = eligible.reduce(into: [:]) {
      if let main = Self.mainIngredientID(of: $1) { $0[$1.databaseID] = main }
    }

    for position in 1...max(1, request.dinnerCount) {
      // Leftovers night (§14 on #52): the pending surplus from earlier dinners covers a full
      // round of eaters, so this slot re-serves the carried dish and reserves nothing new.
      if let eaters = request.weekly?.eatersPerDinner, eaters >= 1,
        pendingLeftoverServings >= eaters, let carried = lastCooked {
        pendingLeftoverServings -= eaters
        let dinnerID = "\(request.planID)-d\(position)"
        dinners.append(
          PlannedDinner(
            position: position, dinnerID: dinnerID, recipe: carried.ref,
            recipeDatabaseID: carried.databaseID, title: carried.title, servings: eaters,
            timeMinutes: carried.timeMinutes, lines: [], leftoverOfDinnerID: carried.dinnerID))
        continue
      }

      // Rank remaining candidates against the pool state after the earlier dinners reserved
      // their bills — the core of "reserve, then repeat" (§7 step 3-4).
      let ranked = eligible
        .filter { candidate in
          // The three-dinner default excludes a recipe outright; the weekly horizon allows a
          // repeat but prices it (§14 on #52).
          request.weekly != nil || !chosen.contains(candidate.databaseID)
        }
        .compactMap { candidate -> (candidate: PlanCandidate, dinner: DinnerAllocation, score: Double)? in
          let servings = request.servings(forPosition: position)
          let dinner = allocateDinner(
            candidate, servings: servings, baseServings: max(1, candidate.baseServings),
            pool: pool, staples: request.stapleIngredientIDs, substitutions: request.substitutions)
          guard dinner.shortRequiredLineCount <= maxShortRequiredLines else { return nil }
          var score = dinner.coverageScore
          if let weekly = request.weekly {
            if chosen.contains(candidate.databaseID) {
              score -= weekly.repeatPenalty
            }
            if let last = lastMainIngredientID,
              let main = mainIngredientByCandidate[candidate.databaseID], main == last {
              score -= weekly.consecutiveMainIngredientPenalty
            }
          }
          return (candidate, dinner, score)
        }
        .sorted { a, b in
          if a.score != b.score {
            return a.score > b.score
          }
          if a.dinner.coveredRatio != b.dinner.coveredRatio {
            return a.dinner.coveredRatio > b.dinner.coveredRatio
          }
          if a.dinner.shortRequiredLineCount != b.dinner.shortRequiredLineCount {
            return a.dinner.shortRequiredLineCount < b.dinner.shortRequiredLineCount
          }
          if a.candidate.timeMinutes != b.candidate.timeMinutes {
            return (a.candidate.timeMinutes ?? .max) < (b.candidate.timeMinutes ?? .max)
          }
          return a.candidate.databaseID < b.candidate.databaseID
        }

      guard let pick = ranked.first else { break }
      chosen.insert(pick.candidate.databaseID)

      // Weekly state: the main-ingredient chain and the surplus a later slot may cover without
      // reserving anything new (§14 on #52).
      lastMainIngredientID = mainIngredientByCandidate[pick.candidate.databaseID]
      if let eaters = request.weekly?.eatersPerDinner, eaters >= 1 {
        pendingLeftoverServings += max(0, request.servings(forPosition: position) - eaters)
      }

      // Reserve what this dinner consumes (originals and substitutes) so later dinners cannot
      // double count it.
      for consumption in pick.dinner.consumed {
        pool.reserve(consumption.ingredientID, grams: consumption.grams)
      }

      let dinnerID = "\(request.planID)-d\(position)"
      let lines = pick.dinner.lines.map { line in
        PlanLine(
          ingredientID: line.ingredientID, name: line.name, isRequired: line.isRequired,
          required: line.required, lineState: line.lineState, short: line.short,
          swap: line.swap)
      }
      dinners.append(
        PlannedDinner(
          position: position, dinnerID: dinnerID, recipe: pick.candidate.ref,
          recipeDatabaseID: pick.candidate.databaseID, title: pick.candidate.title,
          servings: request.servings(forPosition: position),
          timeMinutes: pick.candidate.timeMinutes, lines: lines))
      lastCooked = (
        dinnerID: dinnerID, ref: pick.candidate.ref, databaseID: pick.candidate.databaseID,
        title: pick.candidate.title, timeMinutes: pick.candidate.timeMinutes
      )

      for line in pick.dinner.lines {
        guard line.isRequired else { continue }
        totalLines += 1
        switch line.lineState {
        case .sufficient:
          sufficientLines += 1
        case .short:
          if let short = line.short {
            mergeShopping(short.value, ingredientID: line.ingredientID, name: line.name, into: &shopping)
          }
          attention.append(line.name)
        case .assumedStaple:
          if let required = line.required {
            mergeShopping(
              required.value, ingredientID: line.ingredientID, name: line.name,
              stapleGrams: required.value, into: &shopping)
          }
          attention.append(line.name)
        case .quantityUnknown:
          attention.append(line.name)
        case .needsReconfirming:
          attention.append(line.name)
        }
        if line.swap != nil { swapCount += 1 }
      }
    }

    let shoppingList = shopping
      .sorted { $0.key < $1.key }
      .map { ingredientID, entry in
        // Struck through only when every merged gram came from an assumed-staple line; a real
        // shortfall sharing the ingredient must render as a buy.
        let allStaple = entry.grams > 0 && (entry.grams - entry.stapleGrams) < 1e-6
        return ShoppingLine(
          ingredientID: ingredientID, name: entry.name,
          amount: PlanQuantity(value: entry.grams), assumedStaple: allStaple)
      }

    let fitSummary = PlanFitSummary(
      sufficientLines: sufficientLines, totalLines: totalLines, swapCount: swapCount,
      attention: attention.isEmpty ? nil : attention)

    return LeChefPlan(
      planID: request.planID, createdAt: request.createdAt, dinners: dinners,
      shoppingList: shoppingList, fitSummary: fitSummary)
  }

  // MARK: - Candidate preparation

  /// A recipe's main ingredient: the required line with the largest known gram requirement per
  /// base serving; ties keep the smaller ingredient id. `nil` when no required line carries a
  /// usable quantity, so such recipes never match the consecutive-main penalty.
  static func mainIngredientID(of candidate: PlanCandidate) -> Int64? {
    var best: (id: Int64, grams: Double)?
    for line in candidate.lines where line.isRequired && line.grams > 0 {
      if let current = best {
        if line.grams > current.grams || (line.grams == current.grams && line.ingredientID < current.id) {
          best = (line.ingredientID, line.grams)
        }
      } else {
        best = (line.ingredientID, line.grams)
      }
    }
    return best?.id
  }

  /// Restrictions are a hard filter with zero violations: any required line on a blocked
  /// ingredient excludes the candidate outright.
  private static func restrictionClean(_ candidate: PlanCandidate, blockedUnion: Set<Int64>) -> Bool
  {
    !candidate.lines.contains { line in
      line.isRequired && blockedUnion.contains(line.ingredientID)
    }
  }

  /// Sum duplicate ingredient lines (the database schema prevents them; the guarantee must not
  /// depend on that). A duplicate that is required on any row stays required.
  private static func mergedLines(_ candidate: PlanCandidate) -> PlanCandidate {
    var byIngredient: [Int64: PlanCandidateLine] = [:]
    for line in candidate.lines {
      if let existing = byIngredient[line.ingredientID] {
        byIngredient[line.ingredientID] = PlanCandidateLine(
          ingredientID: line.ingredientID, name: line.name, grams: existing.grams + line.grams,
          isRequired: existing.isRequired || line.isRequired)
      } else {
        byIngredient[line.ingredientID] = line
      }
    }
    return PlanCandidate(
      databaseID: candidate.databaseID, ref: candidate.ref, title: candidate.title,
      timeMinutes: candidate.timeMinutes, baseServings: candidate.baseServings,
      lines: byIngredient.values.sorted { $0.ingredientID < $1.ingredientID })
  }

  // MARK: - One dinner

  struct DinnerLine: Equatable {
    var ingredientID: Int64
    var name: String
    var isRequired: Bool
    var required: PlanQuantity?
    var lineState: PlanLineState
    var short: PlanQuantity?
    var swap: PlanSwap?
  }

  // Not Equatable: `consumed` uses tuples, and no caller needs equality on allocations.
  struct DinnerAllocation {
    var lines: [DinnerLine]
    var consumed: [(ingredientID: Int64, grams: Double)]
    /// 3× use-soon coverage + regular coverage, in grams (§7 step 2).
    var coverageScore: Double
    /// Covered / required, over required lines with a known quantity.
    var coveredRatio: Double
    var shortRequiredLineCount: Int
  }

  /// Allocate one dinner's bill from `pool` without reserving; the caller reserves the returned
  /// `consumed` grams only if this dinner is actually picked.
  static func allocateDinner(
    _ candidate: PlanCandidate, servings: Int, baseServings: Int, pool: StockPool,
    staples: Set<Int64>, substitutions: [PlanSubstitution]
  ) -> DinnerAllocation {
    let scale = Double(max(1, servings)) / Double(max(1, baseServings))
    var lines: [DinnerLine] = []
    var consumed: [(ingredientID: Int64, grams: Double)] = []
    var useSoonCovered = 0.0
    var regularCovered = 0.0
    var requiredTotal = 0.0
    var shortLines = 0

    for line in candidate.lines {
      let requiredGrams = line.grams * scale
      if line.grams <= 0 || requiredGrams <= 0 {
        // Quantity unknown: never sufficient, never a buy amount — "check what you have".
        lines.append(
          DinnerLine(
            ingredientID: line.ingredientID, name: line.name, isRequired: line.isRequired,
            required: nil, lineState: .quantityUnknown, short: nil, swap: nil))
        continue
      }
      if line.isRequired { requiredTotal += requiredGrams }

      let available = pool.availableGrams(line.ingredientID)
      if available <= 0 {
        if line.isRequired {
          if staples.contains(line.ingredientID) {
            // No stock, but the household usually has it: struck through on the list.
            lines.append(
              DinnerLine(
                ingredientID: line.ingredientID, name: line.name, isRequired: true,
                required: PlanQuantity(value: requiredGrams), lineState: .assumedStaple,
                short: nil, swap: nil))
          } else {
            shortLines += 1
            lines.append(
              DinnerLine(
                ingredientID: line.ingredientID, name: line.name, isRequired: true,
                required: PlanQuantity(value: requiredGrams), lineState: .short,
                short: PlanQuantity(value: requiredGrams), swap: nil))
          }
        } else {
          // Optional lines make no availability claim: short is display-only, never blocking,
          // never in the shopping list.
          lines.append(
            DinnerLine(
              ingredientID: line.ingredientID, name: line.name, isRequired: false,
              required: PlanQuantity(value: requiredGrams), lineState: .short,
              short: PlanQuantity(value: requiredGrams), swap: nil))
        }
        continue
      }

      let allocated = min(requiredGrams, available)
      let remainder = requiredGrams - allocated
      consumed.append((ingredientID: line.ingredientID, grams: allocated))
      recordCoverage(allocated, ingredientID: line.ingredientID, pool: pool, into: &useSoonCovered, regular: &regularCovered)

      if remainder <= 1e-9 {
        let state: PlanLineState =
          pool.isEstimateTainted(line.ingredientID) ? .needsReconfirming : .sufficient
        lines.append(
          DinnerLine(
            ingredientID: line.ingredientID, name: line.name, isRequired: line.isRequired,
            required: PlanQuantity(value: requiredGrams), lineState: state, short: nil, swap: nil))
        continue
      }

      // Short. Required lines get one swap attempt; a swap is applied only when the substitute
      // covers the shortfall fully — otherwise the shortfall is reported (no half-swaps).
      if line.isRequired,
        let swap = coveringSubstitution(
          originalID: line.ingredientID, shortfallGrams: remainder, pool: pool,
          substitutions: substitutions)
      {
        let substituteGrams = remainder * swap.substituteGramsPerOriginalGram
        consumed.append((ingredientID: swap.substituteID, grams: substituteGrams))
        recordCoverage(substituteGrams, ingredientID: swap.substituteID, pool: pool, into: &useSoonCovered, regular: &regularCovered)
        let state: PlanLineState =
          pool.isEstimateTainted(swap.substituteID) ? .needsReconfirming : .sufficient
        lines.append(
          DinnerLine(
            ingredientID: line.ingredientID, name: line.name, isRequired: true,
            required: PlanQuantity(value: requiredGrams), lineState: state, short: nil,
            swap: PlanSwap(
              originalID: swap.originalID, substituteID: swap.substituteID, note: swap.note,
              reviewed: swap.reviewed)))
      } else {
        shortLines += 1
        lines.append(
          DinnerLine(
            ingredientID: line.ingredientID, name: line.name, isRequired: line.isRequired,
            required: PlanQuantity(value: requiredGrams), lineState: .short,
            short: PlanQuantity(value: remainder), swap: nil))
      }
    }

    let coveredRatio = requiredTotal > 0 ? min(1, (useSoonCovered + regularCovered) / requiredTotal) : 1
    return DinnerAllocation(
      lines: lines, consumed: consumed, coverageScore: 3 * useSoonCovered + regularCovered,
      coveredRatio: coveredRatio, shortRequiredLineCount: shortLines)
  }

  /// The first substitution whose substitute fully covers the shortfall ("primary-if-covered,
  /// else first covering substitute, else shortfall reported").
  private static func coveringSubstitution(
    originalID: Int64, shortfallGrams: Double, pool: StockPool, substitutions: [PlanSubstitution]
  ) -> PlanSubstitution? {
    substitutions.first { substitution in
      substitution.originalID == originalID
        && pool.availableGrams(substitution.substituteID)
          >= shortfallGrams * substitution.substituteGramsPerOriginalGram - 1e-9
    }
  }

  private static func recordCoverage(
    _ grams: Double, ingredientID: Int64, pool: StockPool, into useSoon: inout Double,
    regular: inout Double
  ) {
    guard let entry = pool.entry(for: ingredientID) else {
      regular += grams
      return
    }
    // A capped split is good enough for ranking: the dinner's consumed share of the use-soon
    // pile counts triple, the rest as regular coverage. Counting the whole pile here would
    // credit stock other dinners consume.
    let soon = min(
      grams, entry.useSoonGrams(withinHorizonDays: pool.useSoonHorizonDays, now: pool.now))
    useSoon += soon
    regular += grams - soon
  }

  private static func mergeShopping(
    _ grams: Double, ingredientID: Int64, name: String, stapleGrams: Double = 0,
    into shopping: inout [Int64: (grams: Double, stapleGrams: Double, name: String)]
  ) {
    let existing = shopping[ingredientID]
    shopping[ingredientID] = (
      grams: (existing?.grams ?? 0) + grams,
      stapleGrams: (existing?.stapleGrams ?? 0) + stapleGrams,
      name: name
    )
  }
}
