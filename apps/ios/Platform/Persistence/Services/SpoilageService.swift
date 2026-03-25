import Foundation

/// Read-focused service for expiry-aware inventory nudges.
final class SpoilageService: Sendable {
  private let inventoryRepository: InventoryRepository

  init(inventoryRepository: InventoryRepository) {
    self.inventoryRepository = inventoryRepository
  }

  func useSoonSuggestions(withinDays: Int = 3, limit: Int = 12) throws
    -> [InventoryUseSoonSuggestion]
  {
    try inventoryRepository.useSoonSuggestions(withinDays: withinDays, limit: limit)
  }
}
