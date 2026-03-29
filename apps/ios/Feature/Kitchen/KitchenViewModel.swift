import SwiftUI

@MainActor
@Observable
final class KitchenViewModel {
  var isLoading = false
  var hasLoaded = false
  var allItems: [InventoryActiveItem] = []
  var selectedLocation: InventoryStorageLocation? = nil
  var pantryAssumptions: [PantryAssumptionDisplay] = []

  private let inventoryRepository: InventoryRepository
  private let pantryAssumptionService: PantryAssumptionService

  init(deps: AppDependencies) {
    self.inventoryRepository = deps.inventoryRepository
    self.pantryAssumptionService = PantryAssumptionService(db: deps.appDatabase.dbQueue)
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
    isLoading = true
    defer {
      isLoading = false
      hasLoaded = true
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
      pantryAssumptions = rawAssumptions.map { assumption in
        PantryAssumptionDisplay(
          ingredientId: assumption.ingredientId,
          ingredientName: IngredientLexicon.displayName(for: assumption.ingredientId),
          tier: assumption.tier
        )
      }
    } catch {
      allItems = []
      pantryAssumptions = []
    }
  }

  // MARK: - Item Actions

  func removeItem(_ item: InventoryActiveItem) async {
    let repo = inventoryRepository
    do {
      try await Task.detached(priority: .userInitiated) {
        try repo.removeActiveItem(id: item.id)
      }.value
      allItems.removeAll { $0.id == item.id }
    } catch {
      await load()
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
    } catch {
      await load()
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
    } catch {
      await load()
    }
  }

  func removePantryAssumption(ingredientId: Int64) async {
    let pantryService = pantryAssumptionService
    do {
      try await Task.detached(priority: .userInitiated) {
        try pantryService.removeAssumption(ingredientId: ingredientId)
      }.value
      pantryAssumptions.removeAll { $0.ingredientId == ingredientId }
    } catch {
      await load()
    }
  }
}
