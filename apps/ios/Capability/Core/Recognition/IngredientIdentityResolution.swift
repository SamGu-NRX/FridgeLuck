import Foundation

/// The order in which a recognized label becomes an ingredient ID.
///
/// Bundled recipes reference only the curated ingredient IDs, so curated foods must win over the
/// broad USDA catalog. Before this ordering, a Vision label such as "bell_pepper" normalized to
/// "bell pepper", missed the bundled name and matched a USDA alias instead, so a real scan's
/// pepper never matched a recipe while the same word read by OCR did.
enum IngredientIdentityResolution {
  static func resolveLabel(
    _ label: String,
    userCorrection: (String) -> Int64?,
    curated: (String) -> Int64?,
    catalog: (String, IngredientCatalogMatching) -> Int64?
  ) -> Int64? {
    userCorrection(label) ?? curated(label) ?? catalog(label, .exact)
  }

  /// Catalog fallback for OCR text the curated lexicon couldn't place. An unsupported phrase
  /// such as "oat milk" is first looked up whole, which is a correct match if the catalog has
  /// it; single-word fallback then runs with those phrases removed so "milk" can't stand in.
  static func resolveTextFromCatalog(
    _ text: String,
    catalogName: (String) -> Int64?,
    catalogTokens: (String) -> Int64?
  ) -> Int64? {
    for phrase in IngredientLexicon.unsupportedFoodPhrases(in: text) {
      if let id = catalogName(phrase) { return id }
    }
    let masked = IngredientLexicon.maskingUnsupportedFoodPhrases(text)
    return masked.isEmpty ? nil : catalogTokens(masked)
  }
}
