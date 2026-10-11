import Foundation
import GRDB
import Observation
import FLFeatureLogic

/// Drives the weekly-plan screen: builds read-only planning inputs from the
/// live household state, runs the pure `WeeklyPlanFlow` reducer, and persists
/// exactly one store entry through the separate `WeeklyPlanStore`.
///
/// Policy (mirrors the planner core's ownership boundaries):
/// - Nothing here reserves or consumes stock. Cooking consumption stays with
///   `InventoryRepository.applyConsumption`, driven by the accepted plan.
/// - Staleness is *displayed*, never auto-fixed: inventory or profile changes
///   re-evaluate the fingerprint, but replacement happens only on the user's
///   explicit recompute.
/// - Candidates are capped at six recipes so the engine keeps its
///   guaranteed-optimal domain (≤ 6 recipes × ≤ 3 slots).
@Observable
@MainActor
final class WeeklyPlanViewModel {
  /// Candidates offered to the planner; the guaranteed-optimal domain tops out
  /// at six recipes.
  static let candidateLimit = 6

  var flowState = WeeklyPlanFlowState()
  var input: WeeklyPlanInput?
  var isLoading = false
  var errorMessage: String?
  var ingredientNames: [Int64: String] = [:]

  private let inventoryRepository: InventoryRepository
  private let recipeRepository: RecipeRepository
  private let ingredientRepository: IngredientRepository
  private let userDataRepository: UserDataRepository
  private let store: WeeklyPlanStore
  private var inventoryObserver: AnyDatabaseCancellable?

  init(
    inventoryRepository: InventoryRepository,
    recipeRepository: RecipeRepository,
    ingredientRepository: IngredientRepository,
    userDataRepository: UserDataRepository,
    store: WeeklyPlanStore
  ) {
    self.inventoryRepository = inventoryRepository
    self.recipeRepository = recipeRepository
    self.ingredientRepository = ingredientRepository
    self.userDataRepository = userDataRepository
    self.store = store
  }

  // MARK: - Loading

  /// Builds fresh inputs and restores the persisted entry, recomputing
  /// staleness against what the kitchen holds right now. Also starts
  /// observing inventory so a changed kitchen shows the stale banner.
  func load() {
    isLoading = true
    defer { isLoading = false }

    do {
      let built = try buildInput()
      input = built
      ingredientNames = try ingredientNameMap(for: built)
      flowState = WeeklyPlanFlow.restore(entry: store.load(), inputs: built)

      if inventoryObserver == nil {
        inventoryObserver = inventoryRepository.observeInventoryChanges { [weak self] in
          self?.kitchenDidChange()
        }
      }
    } catch {
      errorMessage = "Could not load your kitchen: \(error.localizedDescription)"
    }
  }

  /// Inventory moved underneath the plan: refresh inputs and re-derive the
  /// stale flag. Never recomputes — fixing staleness is the user's call.
  private func kitchenDidChange() {
    guard let built = try? buildInput() else { return }
    input = built
    ingredientNames = (try? ingredientNameMap(for: built)) ?? ingredientNames
    flowState = WeeklyPlanFlow.evaluateStaleness(state: flowState, inputs: built)
  }

  private func buildInput() throws -> WeeklyPlanInput {
    let profile = try userDataRepository.fetchHealthProfile()
    let lots = try inventoryRepository.fetchPlanningLots()

    // Deterministic candidate choice: eligible recipes by ID order, capped so
    // the engine stays in its guaranteed-optimal domain.
    let allRecipes = try recipeRepository.fetchAllRecipes(limit: 200)
      .filter { $0.id != nil }
      .sorted { $0.id! < $1.id! }
    let candidates = Array(allRecipes.prefix(Self.candidateLimit))

    var ingredientsByRecipe: [Int64: [(ingredient: Ingredient, quantity: RecipeIngredient)]] = [:]
    for recipe in candidates {
      ingredientsByRecipe[recipe.id!] = try recipeRepository.ingredientsForRecipe(id: recipe.id!)
    }

    return WeeklyPlanInputAdapter.makeInput(
      recipes: candidates,
      ingredientsByRecipe: ingredientsByRecipe,
      lots: lots,
      profile: profile)
  }

  private func ingredientNameMap(for input: WeeklyPlanInput) throws -> [Int64: String] {
    var ids = Set(input.stock.map(\.ingredientId))
    for recipe in input.recipes {
      for need in recipe.needs {
        ids.insert(need.ingredientId)
      }
    }
    let rows = try ingredientRepository.fetch(ids: ids)
    return Dictionary(
      rows.compactMap { row -> (Int64, String)? in
        guard let id = row.id else { return nil }
        return (id, row.name.replacingOccurrences(of: "_", with: " ").localizedCapitalized)
      },
      uniquingKeysWith: { _, last in last })
  }

  // MARK: - Flow actions

  /// Explicit recomputation over fresh inputs, persisted as the new draft.
  func recompute() {
    guard let built = input ?? (try? buildInput()) else {
      errorMessage = errorMessage ?? "Could not read your kitchen."
      return
    }
    input = built
    apply(WeeklyPlanFlow.recompute(state: flowState, inputs: built, now: Date()))
  }

  /// Accepts the current draft (feasible drafts only, per the flow).
  func accept() {
    apply(WeeklyPlanFlow.accept(state: flowState, now: Date()))
  }

  /// Replaces one slot's recipe with a candidate.
  func edit(slotId: Int64, newRecipeId: Int64) {
    guard let built = input else { return }
    apply(WeeklyPlanFlow.editSlot(state: flowState, slotId: slotId, newRecipeId: newRecipeId, inputs: built, now: Date()))
  }

  /// Removes one slot from the plan.
  func remove(slotId: Int64) {
    guard let built = input else { return }
    apply(WeeklyPlanFlow.removeSlot(state: flowState, slotId: slotId, inputs: built, now: Date()))
  }

  /// Clears the plan entirely (start over).
  func discard() {
    flowState = WeeklyPlanFlow.discard(state: flowState)
    try? store.remove()
  }

  /// Applies a flow result and persists it. Rejections change nothing on disk;
  /// their reason stays on the state for the screen to show verbatim.
  private func apply(_ next: WeeklyPlanFlowState) {
    flowState = next
    guard let entry = next.entry else {
      try? store.remove()
      return
    }
    do {
      try store.save(entry)
    } catch {
      errorMessage = "Could not save the plan: \(error.localizedDescription)"
    }
  }

  // MARK: - Screen resolvers

  func ingredientName(_ id: Int64) -> String {
    ingredientNames[id] ?? "#\(id)"
  }

  func recipeTitle(_ id: Int64) -> String? {
    input?.recipes.first(where: { $0.id == id })?.title
      ?? flowState.plan?.assignments.first(where: { $0.recipeId == id })?.recipeTitle
  }

  /// Recipes offered for the edit picker: the planner's candidates, resolved
  /// to their titles.
  var editCandidates: [WeeklyPlanRecipe] {
    guard let plan = flowState.plan, let input else { return [] }
    return plan.candidateRecipeIds.compactMap { id in
      input.recipes.first(where: { $0.id == id })
    }
  }
}

// MARK: - Store factory

extension WeeklyPlanViewModel {
  /// The store lives beside the app database in Application Support, mirroring
  /// `AppDatabase`'s path derivation (read-only with respect to that store).
  static func defaultStore() throws -> WeeklyPlanStore {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return WeeklyPlanStore(directory: directory)
  }
}
