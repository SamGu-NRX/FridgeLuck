import GRDB
import SwiftUI

@MainActor
@Observable
final class KitchenViewModel {
  var isLoading = false
  var hasLoaded = false
  var allItems: [InventoryActiveItem] = []
  var selectedLocation: InventoryStorageLocation? = nil
  var pantryAssumptions: [PantryAssumptionDisplay] = []
  var errorMessage: String?

  private let inventoryRepository: InventoryRepository
  private let pantryAssumptionService: PantryAssumptionService
  @ObservationIgnored private var inventoryObserver: AnyDatabaseCancellable?
  @ObservationIgnored private var isLoadInFlight = false
  @ObservationIgnored private var needsReload = false

  convenience init(deps: AppDependencies) {
    self.init(
      inventoryRepository: deps.inventoryRepository,
      pantryAssumptionService: PantryAssumptionService(db: deps.appDatabase.dbQueue)
    )
  }

  init(inventoryRepository: InventoryRepository, pantryAssumptionService: PantryAssumptionService) {
    self.inventoryRepository = inventoryRepository
    self.pantryAssumptionService = pantryAssumptionService
    // The Kitchen tab stays mounted while hidden, so its initial `.task` load goes stale after
    // a scan or a cooked meal changes inventory elsewhere.
    inventoryObserver = inventoryRepository.observeInventoryChanges { [weak self] in
      guard let self else { return }
      Task { await self.load() }
    }
  }

  // MARK: - Derived Collections

  var useSoonItems: [InventoryActiveItem] {
    allItems.filter { $0.isExpiringSoon }
  }

  var needsReviewItems: [InventoryActiveItem] {
    allItems.filter { $0.averageConfidenceScore < 0.5 }
  }

  var filteredItems: [InventoryActiveItem] {
    guard let location = selectedLocation else { return allItems }
    return allItems.filter { $0.storageLocation == location }
  }

  var groupedByLocation: [InventoryStorageLocation: [InventoryActiveItem]] {
    Dictionary(grouping: filteredItems, by: \.storageLocation)
  }

  var locationCounts: [InventoryStorageLocation: Int] {
    Dictionary(allItems.map { ($0.storageLocation, 1) }, uniquingKeysWith: +)
  }

  var itemCount: Int { allItems.count }

  var expiringCount: Int { useSoonItems.count }

  // MARK: - Data Loading

  func load() async {
    // Coalesce overlapping loads so an observer burst can't land an older snapshot last.
    if isLoadInFlight {
      needsReload = true
      return
    }
    isLoadInFlight = true
    isLoading = true
    defer {
      isLoading = false
      hasLoaded = true
      isLoadInFlight = false
      if needsReload {
        needsReload = false
        Task { await self.load() }
      }
    }

    let repo = inventoryRepository
    let pantryService = pantryAssumptionService
    do {
      let (fetched, rawAssumptions) = try await Task.detached(priority: .userInitiated) {
        let items = try repo.fetchAllActiveItems()
        let assumptions = try pantryService.fetchAll()
        return (items, assumptions)
      }.value
      allItems = fetched
      keepSelectionVisible()
      pantryAssumptions = rawAssumptions.map { assumption in
        PantryAssumptionDisplay(
          ingredientId: assumption.ingredientId,
          ingredientName: IngredientLexicon.displayName(for: assumption.ingredientId),
          tier: assumption.tier
        )
      }
      errorMessage = nil
    } catch {
      errorMessage = "We couldn't load your kitchen right now. Pull to refresh and try again."
    }
  }

  /// A filter whose location just ran out of items has no chip left to clear it, and would
  /// hide everything else, so it falls back to All.
  private func keepSelectionVisible() {
    let kept = KitchenLocationOrder.selection(selectedLocation, counts: locationCounts)
    if kept != selectedLocation { selectedLocation = kept }
  }

  // MARK: - Item Actions

  func removeItem(_ item: InventoryActiveItem) async {
    let repo = inventoryRepository
    do {
      try await Task.detached(priority: .userInitiated) {
        try repo.removeActiveItem(id: item.id)
      }.value
      allItems.removeAll { $0.id == item.id }
      keepSelectionVisible()
      errorMessage = nil
    } catch {
      await load()
      errorMessage = "We couldn't remove \(item.ingredientName). Please try again."
    }
  }

  func confirmItem(_ item: InventoryActiveItem) async {
    let repo = inventoryRepository
    do {
      try await Task.detached(priority: .userInitiated) {
        try repo.confirmActiveItem(id: item.id)
      }.value
      if let index = allItems.firstIndex(where: { $0.id == item.id }) {
        allItems[index] = allItems[index].withConfirmedConfidence()
      }
      errorMessage = nil
    } catch {
      await load()
      errorMessage = "We couldn't confirm \(item.ingredientName). Please try again."
    }
  }

  // MARK: - Pantry Assumptions

  func cyclePantryTier(ingredientId: Int64) async {
    guard let index = pantryAssumptions.firstIndex(where: { $0.ingredientId == ingredientId })
    else { return }
    let current = pantryAssumptions[index]
    let newTier = current.tier.next

    let pantryService = pantryAssumptionService
    do {
      try await Task.detached(priority: .userInitiated) {
        try pantryService.setAssumption(ingredientId: ingredientId, tier: newTier)
      }.value
      pantryAssumptions[index] = PantryAssumptionDisplay(
        ingredientId: ingredientId,
        ingredientName: current.ingredientName,
        tier: newTier
      )
      errorMessage = nil
    } catch {
      await load()
      errorMessage = "We couldn't update \(current.ingredientName). Please try again."
    }
  }

  func removePantryAssumption(ingredientId: Int64) async {
    let pantryService = pantryAssumptionService
    do {
      try await Task.detached(priority: .userInitiated) {
        try pantryService.removeAssumption(ingredientId: ingredientId)
      }.value
      pantryAssumptions.removeAll { $0.ingredientId == ingredientId }
      errorMessage = nil
    } catch {
      await load()
      let ingredientName =
        pantryAssumptions.first(where: { $0.ingredientId == ingredientId })?.ingredientName
        ?? "that staple"
      errorMessage = "We couldn't remove \(ingredientName). Please try again."
    }
  }

  func addPantryAssumptions(ingredientIDs: Set<Int64>) async {
    let existingIDs = Set(pantryAssumptions.map(\.ingredientId))
    let newIDs = ingredientIDs.subtracting(existingIDs)
    guard !newIDs.isEmpty else { return }

    let pantryService = pantryAssumptionService
    do {
      try await Task.detached(priority: .userInitiated) {
        try pantryService.setAssumptions(ingredientIDs: newIDs, tier: .alwaysHave)
      }.value
      await load()
      errorMessage = nil
    } catch {
      await load()
      errorMessage = "We couldn't save those pantry staples. Please try again."
    }
  }
}

/// Display order for the Kitchen's storage sections and filter chips. "Other" holds items with
/// no known storage location (olive oil, which has no storage tip) and comes last.
enum KitchenLocationOrder {
  static let all: [InventoryStorageLocation] = [.fridge, .pantry, .freezer, .unknown]

  /// One chip per location that has items. The chip row used to skip "Other", so its section
  /// had no chip (2026-10-07 walk, screenshot 41).
  /// The selection to keep after items change: nil (All) once its location has no items.
  static func selection(
    _ selected: InventoryStorageLocation?,
    counts: [InventoryStorageLocation: Int]
  ) -> InventoryStorageLocation? {
    guard let selected, counts[selected, default: 0] > 0 else { return nil }
    return selected
  }

  static func chipLocations(counts: [InventoryStorageLocation: Int]) -> [InventoryStorageLocation] {
    all.filter { counts[$0, default: 0] > 0 }
  }
}
