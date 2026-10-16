import Foundation
import Observation

/// What the persistence layer hands the plan sheet: everything one allocation run needs, read in
/// one database snapshot. The view model recomputes from this cache — allocation never re-queries.
public struct PlanSheetData: Equatable, Sendable {
  public let candidates: [PlanCandidate]
  public let eaters: [PlanEater]
  public let substitutions: [PlanSubstitution]
  public let stapleIngredientIDs: Set<Int64>
  public let pool: StockPool
  /// Whether any inventory lots exist at all (before expiry filtering). A kitchen never scanned
  /// has none, and the sheet says so instead of faking a plan.
  public let hasAnyStockLots: Bool

  public init(
    candidates: [PlanCandidate], eaters: [PlanEater], substitutions: [PlanSubstitution],
    stapleIngredientIDs: Set<Int64>, pool: StockPool, hasAnyStockLots: Bool
  ) {
    self.candidates = candidates
    self.eaters = eaters
    self.substitutions = substitutions
    self.stapleIngredientIDs = stapleIngredientIDs
    self.pool = pool
    self.hasAnyStockLots = hasAnyStockLots
  }
}

/// Query the snapshot provider runs under (frozen `now` keeps tests deterministic).
public struct PlanSheetQuery: Equatable, Sendable {
  public let now: Date
  public let useSoonHorizonDays: Int

  public init(now: Date, useSoonHorizonDays: Int = 3) {
    self.now = now
    self.useSoonHorizonDays = useSoonHorizonDays
  }
}

/// View model for the plan sheet (SPEC.md §3.2), no views: states, dinner count, per-dinner
/// servings, swap one dinner, recompute. Pure logic — a `PlanSheet` view renders `state`.
@MainActor
@Observable
public final class PlanSheetViewModel {
  public enum State: Equatable, Sendable {
    case idle
    case loading
    /// Kitchen never scanned — no inventory lots exist. "I don't know your kitchen yet."
    case empty
    /// Candidates exist, but none is selectable. Honest states, shopping-list-first.
    case nothingFeasible
    /// A plan is on screen. `sparseKitchen` marks fewer dinners than requested.
    case ready
  }

  public private(set) var state: State = .idle
  public private(set) var plan: LeChefPlan?
  /// True when the plan has fewer dinners than the requested count — shown honestly, never
  /// padded with fake feasibility.
  public private(set) var sparseKitchen: Bool = false
  public private(set) var errorMessage: String?
  public private(set) var dinnerCount: Int = 3
  /// Five-to-seven dinners run the weekly horizon (SPEC.md §14, #52 adapted): the same
  /// allocator with repeats priced, back-to-back mains penalized, and surplus servings
  /// carried into a later leftovers slot. Three-to-four keep the strict no-repeat default.
  public var isWeeklyHorizon: Bool { (5...7).contains(dinnerCount) }
  /// Coverage-equivalent cost of choosing a recipe already chosen in this plan.
  public nonisolated static let weeklyRepeatPenalty: Double = 1_000
  /// Coverage-equivalent cost of repeating yesterday's main ingredient.
  public nonisolated static let weeklyConsecutiveMainPenalty: Double = 500

  private var data: PlanSheetData?
  private var servingsPerDinner: [Int] = []
  private let defaultServings = 2
  private let provider: @Sendable (PlanSheetQuery) async throws -> PlanSheetData
  private let now: Date

  public init(
    now: Date = Date(),
    provider: @escaping @Sendable (PlanSheetQuery) async throws -> PlanSheetData
  ) {
    self.now = now
    self.provider = provider
  }

  /// Reads the snapshot once and computes the first plan.
  public func load() async {
    state = .loading
    errorMessage = nil
    do {
      let loaded = try await provider(PlanSheetQuery(now: now, useSoonHorizonDays: 3))
      data = loaded
      // No stock ever recorded: the kitchen was never scanned. Say so instead of faking a plan.
      if !loaded.hasAnyStockLots {
        state = .empty
        plan = nil
        return
      }
      servingsPerDinner = []
      recompute()
    } catch {
      errorMessage = "Couldn't read your kitchen. Try again."
      state = .idle
    }
  }

  /// Choose how many dinners (1...7, per the plan contract).
  public func setDinnerCount(_ count: Int) {
    guard count >= 1, count <= 7, count != dinnerCount else { return }
    dinnerCount = count
    recompute()
  }

  /// Change servings for one dinner; allocation re-runs for the whole plan.
  public func setServings(_ servings: Int, forDinnerAt index: Int) {
    guard servings >= 1, index >= 0, index < dinnerCount else { return }
    while servingsPerDinner.count <= index { servingsPerDinner.append(defaultServings) }
    servingsPerDinner[index] = servings
    recompute()
  }

  /// Swap one dinner: the recipe at `index` is excluded from ranking and the whole plan
  /// re-allocates against the same frozen pool. The other picks stay in the plan unless the
  /// reshuffled reservations genuinely rank something else higher — deterministic either way.
  public func replaceDinner(at index: Int) {
    guard let current = plan, index >= 0, index < current.dinners.count else { return }
    let excluded: Set<Int64> = [current.dinners[index].recipeDatabaseID]
    recompute(excluding: excluded)
  }

  /// Regenerate: exclude every current pick once; if that yields nothing, fall back to the full
  /// ranking rather than showing an empty sheet.
  public func regenerate() {
    guard let current = plan else { return }
    let excluded = Set(current.dinners.map { $0.recipeDatabaseID })
    recompute(excluding: excluded)
    if plan?.dinners.isEmpty == true {
      recompute()
    }
  }

  // MARK: - Recompute

  private func recompute(excluding excluded: Set<Int64> = []) {
    guard let data else { return }
    while servingsPerDinner.count < dinnerCount { servingsPerDinner.append(defaultServings) }
    // Weekly rules ride the same allocator; nil keeps the three-dinner default byte-for-byte.
    let weekly: PlanWeeklyPolicy? =
      isWeeklyHorizon
      ? PlanWeeklyPolicy(
        eatersPerDinner: defaultServings,
        repeatPenalty: Self.weeklyRepeatPenalty,
        consecutiveMainIngredientPenalty: Self.weeklyConsecutiveMainPenalty)
      : nil
    let request = PlanRequest(
      dinnerCount: dinnerCount, servingsPerDinner: servingsPerDinner, candidates: data.candidates,
      eaters: data.eaters, substitutions: data.substitutions,
      stapleIngredientIDs: data.stapleIngredientIDs, pool: data.pool,
      excludeDatabaseIDs: excluded, weekly: weekly,
      planID: plan?.planID ?? Self.makePlanID(now: now),
      createdAt: now)
    let computed = PlanAllocating.allocate(request)
    plan = computed
    sparseKitchen = computed.dinners.count < dinnerCount
    state = computed.dinners.isEmpty ? .nothingFeasible : .ready
  }

  static func makePlanID(now: Date) -> String {
    // plan_[A-Za-z0-9]+ per the contract; millisecond timestamp + counter-free entropy.
    let token = String(format: "%012llx", UInt64(bitPattern: Int64(now.timeIntervalSince1970 * 1_000)))
    return "plan_\(token)"
  }
}
