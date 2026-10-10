import FLBarcode
import Foundation
import os

/// App-side wiring for barcode intake: the catalog resolver over the ingredient
/// repository, the committer over PR42's session path, and the lookup factory
/// (pinned cache in front of a transport; live network is opt-in).
enum BarcodeIntakeWiring {
  /// Live Open Food Facts lookups are opt-in: barcode intake is fully usable offline
  /// (misses become drafts the user resolves), and no test depends on the network.
  static let liveNetworkDefaultsKey = "barcode.intake.liveNetworkEnabled"

  /// OFF asks API clients to identify themselves.
  static let openFoodFactsUserAgent = "FridgeLuck/1.0 (iOS; contact: sgu07966@gmail.com)"

  static func makeLookup() -> BarcodeProductLookup {
    let transport: BarcodeTransport =
      UserDefaults.standard.bool(forKey: liveNetworkDefaultsKey)
      ? OpenFoodFactsTransport(userAgent: openFoodFactsUserAgent)
      : NullBarcodeTransport()
    return PinnedLookupCache(transport: transport)
  }

  /// MainActor: BarcodeIntakeCoordinator is a @MainActor state machine and intake
  /// screens construct it from SwiftUI onAppear/task contexts.
  @MainActor
  static func makeCoordinator(deps: AppDependencies) -> BarcodeIntakeCoordinator {
    BarcodeIntakeCoordinator(
      lookup: makeLookup(),
      resolver: IngredientCatalogBarcodeResolver(repository: deps.ingredientRepository),
      committer: IntakeServiceBarcodeCommitter(
        intakeService: deps.inventoryIntakeService,
        ingredientRepository: deps.ingredientRepository))
  }
}

/// Maps product/brand text onto ingredient-catalog candidates through the repository's
/// search, scored with the shared `CatalogScoring` shape. Search failures log and return
/// no suggestions — the draft stays unbound for a manual pick, never a silent guess.
struct IngredientCatalogBarcodeResolver: BarcodeCatalogResolver {
  private let search: @Sendable (String) -> [Ingredient]

  init(repository: IngredientRepository) {
    self.search = { query in
      do {
        return try repository.search(query: query, limit: 8)
      } catch {
        Logger(subsystem: "samgu.FridgeLuck", category: "BarcodeCatalogResolver")
          .error("Ingredient search failed: \(error.localizedDescription)")
        return []
      }
    }
  }

  /// Injectable search for tests.
  init(search: @escaping @Sendable (String) -> [Ingredient]) {
    self.search = search
  }

  func candidates(for productName: String?, brands: String?) -> [CatalogCandidate] {
    let queryTokens = CatalogScoring.tokens(
      in: [productName, brands].compactMap { $0 }.joined(separator: " "))
    guard !queryTokens.isEmpty else { return [] }

    // Search by the longest tokens first; each probe is a catalog query, so bound the work.
    let probes = Array(queryTokens.sorted { $0.count > $1.count }.prefix(4))
    var best: [Int64: CatalogCandidate] = [:]
    for probe in probes {
      for ingredient in search(probe) {
        guard let id = ingredient.id else { continue }
        let target = CatalogScoring.tokens(in: ingredient.name)
        guard let score = CatalogScoring.score(query: queryTokens, target: target) else { continue }
        if let existing = best[id], existing.score >= score { continue }
        best[id] = CatalogCandidate(id: id, name: ingredient.name, score: score)
      }
    }
    return best.values.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.id < rhs.id
    }
  }
}

/// Commits resolved barcode drafts through PR42's existing session path
/// (`InventoryIntakeService.ingestGrocerySession`). The coordinator owns the stable
/// session source ref, so retries and double commits stay idempotent at the service.
struct IntakeServiceBarcodeCommitter: BarcodeSessionCommitting {
  let intakeService: InventoryIntakeService
  let ingredientRepository: IngredientRepository

  func commit(items: [BarcodeCommitItem], sourceRef: String) async throws -> Int {
    var ingestItems: [InventoryIntakeService.GroceryIngestItem] = []
    ingestItems.reserveCapacity(items.count)
    for item in items {
      let ingredient: Ingredient?
      do {
        ingredient = try ingredientRepository.fetch(id: item.ingredientId)
      } catch {
        Logger(subsystem: "samgu.FridgeLuck", category: "BarcodeCommit")
          .error("Ingredient fetch failed: \(error.localizedDescription)")
        ingredient = nil
      }
      ingestItems.append(Self.ingestItem(from: item, ingredient: ingredient))
    }
    let summary = try intakeService.ingestGrocerySession(
      items: ingestItems,
      sourceRef: sourceRef
    )
    return summary.lotsAdded
  }

  /// Pure mapping, testable without a database: package-mass amounts commit as
  /// `.measured`, user-set amounts as `.entered`; source is `.scan`; location infers
  /// from the ingredient name like every other intake path.
  static func ingestItem(
    from item: BarcodeCommitItem,
    ingredient: Ingredient?
  ) -> InventoryIntakeService.GroceryIngestItem {
    InventoryIntakeService.GroceryIngestItem(
      ingredientId: item.ingredientId,
      quantityGrams: item.quantityGrams,
      storageLocation: InventoryIntakeService.inferLocation(for: ingredient),
      confidenceScore: item.confidence,
      source: .scan,
      quantityProvenance: item.isMeasured ? .measured : .entered
    )
  }
}
