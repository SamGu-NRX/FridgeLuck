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
  /// The plan the household saved last, read in the same snapshot, or `nil`. The sheet opens on
  /// its picks, and whatever the sheet saves next replaces it under the same plan ID, so `pool`
  /// must not subtract this plan's own reservations. The reader drops dinners the household may
  /// no longer eat, so this can hold fewer dinners than were saved.
  public let savedPlan: LeChefPlan?
  /// How many dinners the saved record holds before that screen; 0 without a saved plan.
  public let savedPlanDinnerCount: Int

  public init(
    candidates: [PlanCandidate], eaters: [PlanEater], substitutions: [PlanSubstitution],
    stapleIngredientIDs: Set<Int64>, pool: StockPool, hasAnyStockLots: Bool,
    savedPlan: LeChefPlan? = nil, savedPlanDinnerCount: Int = 0
  ) {
    self.candidates = candidates
    self.eaters = eaters
    self.substitutions = substitutions
    self.stapleIngredientIDs = stapleIngredientIDs
    self.pool = pool
    self.hasAnyStockLots = hasAnyStockLots
    self.savedPlan = savedPlan
    self.savedPlanDinnerCount = savedPlanDinnerCount
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
/// servings, swap one dinner, recompute, save. Pure logic — `PlanSheetView` renders `state`
/// through `PlanSheetContent`.
///
/// Edits keep what the user already sees: changing servings or the dinner count, or swapping
/// one dinner, pins every other dinner to its recipe and re-allocates their lines against the
/// pool the change leaves. Only `regenerate()` asks for different dinners across the board.
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

  public enum SaveStatus: Equatable, Sendable {
    /// The plan on screen differs from the saved record, or nothing was saved.
    case unsaved
    case saving
    /// The plan on screen is the saved record.
    case saved
    case failed
  }

  public private(set) var state: State = .idle
  public private(set) var plan: LeChefPlan?
  /// True when the plan has fewer dinners than the requested count — shown honestly, never
  /// padded with fake feasibility.
  public private(set) var sparseKitchen: Bool = false
  public private(set) var errorMessage: String?
  public private(set) var dinnerCount: Int = 3
  /// In `.nothingFeasible`, the same dinner count planned with no cap on short lines: what a
  /// shop would make possible. `nil` when no candidate survived the household screen at all.
  public private(set) var shoppingFirstPlan: LeChefPlan?
  public private(set) var saveStatus: SaveStatus = .unsaved
  /// One line about the last action when it could not do what was asked (a swap with nothing
  /// to swap in) or when the saved plan had to change on open. Cleared by the next action.
  public private(set) var notice: String?
  /// Five-to-seven dinners run the weekly horizon (SPEC.md §14, #52 adapted): the same
  /// allocator with repeats priced, back-to-back mains penalized, and surplus servings
  /// carried into a later leftovers slot. Three-to-four keep the strict no-repeat default.
  public var isWeeklyHorizon: Bool { (5...7).contains(dinnerCount) }
  /// Coverage-equivalent cost of choosing a recipe already chosen in this plan.
  public nonisolated static let weeklyRepeatPenalty: Double = 1_000
  /// Coverage-equivalent cost of repeating yesterday's main ingredient.
  public nonisolated static let weeklyConsecutiveMainPenalty: Double = 500

  /// Saving needs a saver, a plan on screen, something not yet saved, and no save in flight.
  public var canSave: Bool {
    saver != nil && state == .ready && plan?.dinners.isEmpty == false
      && !saveInFlight && saveStatus != .saved
  }

  /// Whether this sheet can persist a plan at all (a saver was supplied).
  public var supportsSaving: Bool { saver != nil }

  /// Whether the household screen admitted any recipe. When it admitted none, the
  /// nothing-feasible state has no shopping list to offer either.
  public var hasCandidates: Bool { !(data?.candidates.isEmpty ?? true) }

  private var data: PlanSheetData?
  private var servingsPerDinner: [Int] = []
  private let defaultServings = 2
  /// One plan identity per sheet: the saved plan's when one was restored, so saving again
  /// replaces that record instead of stacking a second plan's reservations on the pantry.
  private var planID: String?
  private var savedRecord: LeChefPlan?
  /// Separate from `saveStatus`, which edits rewrite: one save at a time.
  private var saveInFlight = false
  private let provider: @Sendable (PlanSheetQuery) async throws -> PlanSheetData
  private let saver: (@Sendable (LeChefPlan) async throws -> Void)?
  private let now: Date

  public init(
    now: Date = Date(),
    provider: @escaping @Sendable (PlanSheetQuery) async throws -> PlanSheetData,
    saver: (@Sendable (LeChefPlan) async throws -> Void)? = nil
  ) {
    self.now = now
    self.provider = provider
    self.saver = saver
  }

  /// Reads the snapshot once, then shows the saved plan or computes the first one.
  public func load() async {
    state = .loading
    errorMessage = nil
    notice = nil
    do {
      let loaded = try await provider(PlanSheetQuery(now: now, useSoonHorizonDays: 3))
      data = loaded
      plan = nil
      shoppingFirstPlan = nil
      savedRecord = nil
      planID = nil
      saveStatus = .unsaved
      // No stock ever recorded: the kitchen was never scanned. Say so instead of faking a plan.
      if !loaded.hasAnyStockLots {
        state = .empty
        return
      }
      servingsPerDinner = []
      if let saved = loaded.savedPlan {
        restore(saved, storedDinnerCount: loaded.savedPlanDinnerCount)
      } else {
        recompute()
      }
    } catch {
      errorMessage = "Couldn't read your kitchen. Try again."
      state = .idle
    }
  }

  /// Choose how many dinners (1...7, per the plan contract). Dinners already on screen stay;
  /// a longer plan adds dinners after them, a shorter one drops the last ones.
  public func setDinnerCount(_ count: Int) {
    guard count >= 1, count <= 7, count != dinnerCount else { return }
    notice = nil
    dinnerCount = count
    recompute(pinning: Self.pins(plan?.dinners ?? [], through: count))
  }

  /// Change servings for one dinner; every dinner's lines re-allocate, and the picks stay.
  /// A leftovers night has no servings of its own to change.
  public func setServings(_ servings: Int, forDinnerAt index: Int) {
    guard servings >= 1, index >= 0, index < dinnerCount else { return }
    if let dinners = plan?.dinners, index < dinners.count,
      dinners[index].leftoverOfDinnerID != nil
    {
      return
    }
    notice = nil
    while servingsPerDinner.count <= index { servingsPerDinner.append(defaultServings) }
    servingsPerDinner[index] = servings
    recompute(pinning: Self.pins(plan?.dinners ?? []))
  }

  /// Swap one dinner: the recipe at `index` is excluded at that position, every other dinner is
  /// pinned, and the plan re-allocates against the same frozen pool. When no other recipe can
  /// take that night, the plan stays as it was and `notice` says so.
  public func replaceDinner(at index: Int) {
    guard let current = plan, index >= 0, index < current.dinners.count else { return }
    let old = current.dinners[index]
    guard old.leftoverOfDinnerID == nil else { return }
    notice = nil
    var pins = Self.pins(current.dinners)
    pins[old.position] = nil
    guard let request = makeRequest(excluding: [old.recipeDatabaseID], pinning: pins) else {
      return
    }
    let computed = PlanAllocating.allocate(request)
    let replacement = computed.dinners.first { $0.position == old.position }
    guard let replacement, replacement.leftoverOfDinnerID == nil,
      replacement.recipeDatabaseID != old.recipeDatabaseID
    else {
      notice = "Nothing else fits that night from your kitchen."
      return
    }
    apply(computed, request: request)
  }

  /// Regenerate: exclude every current pick once; if that yields nothing, fall back to the full
  /// ranking rather than showing an empty sheet.
  public func regenerate() {
    guard let current = plan else { return }
    notice = nil
    let excluded = Set(current.dinners.map { $0.recipeDatabaseID })
    recompute(excluding: excluded)
    if plan?.dinners.isEmpty == true {
      recompute()
    }
  }

  /// Saves the plan on screen as the household's plan, replacing the record it was restored
  /// from. Edits made while the save runs leave the status `.unsaved`.
  public func save() async {
    guard canSave, let saver, let toSave = plan else { return }
    saveInFlight = true
    saveStatus = .saving
    defer { saveInFlight = false }
    do {
      try await saver(toSave)
      savedRecord = toSave
      saveStatus = plan == toSave ? .saved : .unsaved
    } catch {
      saveStatus = .failed
    }
  }

  // MARK: - Recompute

  /// Opens on the saved plan's picks, re-allocated against today's pool (SPEC.md §7: a saved
  /// plan re-allocates on open, and says so when the result changed, never silently). The
  /// recipes come from the snapshot's admitted candidates, so a saved dinner the household may
  /// no longer be offered cannot come back; its position is planned again.
  private func restore(_ saved: LeChefPlan, storedDinnerCount: Int) {
    planID = saved.planID
    savedRecord = saved
    let count = max(storedDinnerCount, saved.dinners.map(\.position).max() ?? 0)
    dinnerCount = min(7, max(1, count))
    servingsPerDinner = (1...dinnerCount).map { position in
      saved.dinners.first { $0.position == position }?.servings ?? defaultServings
    }
    let withdrawn = saved.dinners.count < storedDinnerCount
    // The reader already dropped withdrawn dinners from `saved`, but the record on disk still
    // holds them: nothing on screen matches it until the user saves again.
    if withdrawn { savedRecord = nil }
    recompute(pinning: Self.pins(saved.dinners))
    guard let current = plan else { return }
    if withdrawn || Self.picks(current) != Self.picks(saved) {
      notice = "Part of your saved plan no longer fits your kitchen or household, so it changed."
    } else if saveStatus != .saved {
      notice = "Your kitchen changed since you saved this plan, so the amounts were updated."
    }
  }

  private func recompute(excluding excluded: Set<Int64> = [], pinning pins: [Int: Int64] = [:]) {
    guard let request = makeRequest(excluding: excluded, pinning: pins) else { return }
    apply(PlanAllocating.allocate(request), request: request)
  }

  private func makeRequest(excluding excluded: Set<Int64>, pinning pins: [Int: Int64])
    -> PlanRequest?
  {
    guard let data else { return nil }
    while servingsPerDinner.count < dinnerCount { servingsPerDinner.append(defaultServings) }
    // Weekly rules ride the same allocator; nil keeps the three-dinner default byte-for-byte.
    let weekly: PlanWeeklyPolicy? =
      isWeeklyHorizon
      ? PlanWeeklyPolicy(
        eatersPerDinner: defaultServings,
        repeatPenalty: Self.weeklyRepeatPenalty,
        consecutiveMainIngredientPenalty: Self.weeklyConsecutiveMainPenalty)
      : nil
    let id = planID ?? Self.makePlanID(now: now)
    planID = id
    return PlanRequest(
      dinnerCount: dinnerCount, servingsPerDinner: servingsPerDinner, candidates: data.candidates,
      eaters: data.eaters, substitutions: data.substitutions,
      stapleIngredientIDs: data.stapleIngredientIDs, pool: data.pool,
      excludeDatabaseIDs: excluded, weekly: weekly, pinnedRecipeByPosition: pins,
      planID: id, createdAt: now)
  }

  private func apply(_ computed: LeChefPlan, request: PlanRequest) {
    plan = computed
    sparseKitchen = computed.dinners.count < dinnerCount
    if computed.dinners.isEmpty {
      let shoppingFirst = PlanAllocating.allocateShoppingFirst(request)
      shoppingFirstPlan = shoppingFirst.dinners.isEmpty ? nil : shoppingFirst
      state = .nothingFeasible
    } else {
      shoppingFirstPlan = nil
      state = .ready
    }
    if saveInFlight { return }  // `save()` settles the status when the write returns.
    saveStatus =
      savedRecord.map { Self.fingerprint($0) == Self.fingerprint(computed) } == true
      ? .saved : .unsaved
  }

  /// What a plan decides: which recipe at which position, for how many, and which nights are
  /// leftovers. Titles and cook times are not part of it (a saved record reads them back
  /// differently).
  private struct Pick: Equatable {
    let position: Int
    let recipeDatabaseID: Int64
    let servings: Int
    let leftoverOfDinnerID: String?
  }

  /// One line's pantry claim, for telling whether a saved record still matches the screen.
  private struct LineClaim: Equatable {
    let ingredientID: Int64
    let isRequired: Bool
    let state: PlanLineState
    let required: Double?
    let short: Double?
    let substituteID: Int64?
    /// A swap reserves from two ingredients; the split is part of the claim.
    let originalGrams: Double?
    let substituteGrams: Double?
  }

  private static func picks(_ plan: LeChefPlan) -> [Pick] {
    plan.dinners.map {
      Pick(
        position: $0.position, recipeDatabaseID: $0.recipeDatabaseID, servings: $0.servings,
        leftoverOfDinnerID: $0.leftoverOfDinnerID)
    }
  }

  /// The decision plus every line's claim on the pantry: equal fingerprints mean the record
  /// on disk says what the screen says.
  private struct Fingerprint: Equatable {
    let picks: [Pick]
    let lines: [[LineClaim]]
  }

  private static func fingerprint(_ plan: LeChefPlan) -> Fingerprint {
    Fingerprint(
      picks: picks(plan),
      lines: plan.dinners.map { dinner in
        dinner.lines.map {
          LineClaim(
            ingredientID: $0.ingredientID, isRequired: $0.isRequired, state: $0.lineState,
            required: $0.required?.value, short: $0.short?.value,
            substituteID: $0.swap?.substituteID, originalGrams: $0.swap?.originalGrams,
            substituteGrams: $0.swap?.substituteGrams)
        }
      })
  }

  /// Positions to keep, from fresh dinners only: a leftovers night follows from the surplus
  /// rules, not from a pick.
  private static func pins(_ dinners: [PlannedDinner], through count: Int = .max) -> [Int: Int64] {
    dinners
      .filter { $0.leftoverOfDinnerID == nil && $0.position <= count }
      .reduce(into: [:]) { $0[$1.position] = $1.recipeDatabaseID }
  }

  static func makePlanID(now: Date) -> String {
    // plan_[A-Za-z0-9]+ per the contract; millisecond timestamp + counter-free entropy.
    let token = String(format: "%012llx", UInt64(bitPattern: Int64(now.timeIntervalSince1970 * 1_000)))
    return "plan_\(token)"
  }
}
