enum OnboardingAllergenCatalogLoader {
  static func load(from ingredientRepository: IngredientRepository) async -> AllergenCatalogIndex {
    let start = OnboardingPerformanceProfiler.begin("allergen_catalog_preload")

    let catalog = await Task.detached(priority: .utility) {
      let fetchedIngredients = (try? ingredientRepository.fetchAll()) ?? []
      return AllergenSupport.buildCatalog(from: fetchedIngredients)
    }.value

    OnboardingPerformanceProfiler.end("allergen_catalog_preload", from: start)
    return catalog
  }
}
