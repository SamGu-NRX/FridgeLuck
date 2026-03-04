import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// AI-enhanced ingredient normalization using Foundation Models (iOS 26+).
/// Falls back to lexical normalization when unavailable.
enum AIIngredientNormalizer {
  #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct NormalizedIngredient {
      @Guide(description: "Ingredient name in singular plain English")
      let name: String

      @Guide(description: "True only when this item is a food ingredient")
      let isFood: Bool
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func aiNormalize(_ labels: [String]) async throws -> [String] {
      guard case .available = SystemLanguageModel.default.availability else {
        return labels
      }

      let session = LanguageModelSession(
        instructions: """
          Normalize ingredient names to concise singular terms.
          Return only food ingredients and remove non-food labels.
          """
      )
      let prompt = "Normalize these labels: \(labels.joined(separator: ", "))"
      let response = try await session.respond(
        to: prompt,
        generating: [NormalizedIngredient].self
      )

      let cleaned = response.content
        .filter(\.isFood)
        .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

      return cleaned.isEmpty ? labels : cleaned
    }
  #endif

  /// Normalize labels using AI when available, otherwise return input unchanged.
  static func enhancedNormalize(_ labels: [String]) async -> [String] {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 26.0, *) {
        if let normalized = try? await aiNormalize(labels) {
          return normalized
        }
      }
    #endif

    return labels
  }
}
