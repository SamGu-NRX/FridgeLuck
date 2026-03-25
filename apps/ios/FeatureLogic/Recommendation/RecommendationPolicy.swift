public enum RecommendationPolicy {
  public static let fallbackIngredientIDs: Set<Int64> = [1, 2, 5, 6]

  public static func effectiveIngredientIDs(from ingredientIDs: Set<Int64>) -> Set<Int64> {
    ingredientIDs.isEmpty ? fallbackIngredientIDs : ingredientIDs
  }

  public static func nearMatchLimit(hasExactMatches: Bool) -> Int {
    hasExactMatches ? 8 : 20
  }

  public static func shouldWidenNearMatchSearch(
    exactCount: Int,
    nearMatchCount: Int
  ) -> Bool {
    exactCount == 0 && nearMatchCount == 0
  }
}
