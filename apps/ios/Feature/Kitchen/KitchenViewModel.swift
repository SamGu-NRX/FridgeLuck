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
      errorMessage = nil
    } catch {
      errorMessage = "We couldn't load your kitchen right now. Pull to refresh and try again."
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
