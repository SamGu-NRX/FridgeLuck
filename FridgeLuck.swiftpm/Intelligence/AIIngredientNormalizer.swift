import Foundation

/// AI-enhanced ingredient normalization using Foundation Models (iOS 26+).
/// Falls back to IngredientLexicon when unavailable.
///
/// When building with Xcode 26 / iOS 26 SDK, uncomment the Foundation Models code below.
enum AIIngredientNormalizer {

  // MARK: - AI Normalizer (iOS 26+)
  // Uncomment when building with iOS 26 SDK:
  //
  // import FoundationModels
  //
  // @available(iOS 26, macOS 26, *)
  // @Generable
  // struct NormalizedIngredient {
  //     @Guide(description: "The standard ingredient name in singular form")
  //     let name: String
  //     @Guide(description: "Whether this is actually a food item")
  //     let isFood: Bool
  // }
  //
  // @available(iOS 26, macOS 26, *)
  // static func aiNormalize(_ labels: [String]) async throws -> [String] {
  //     guard SystemLanguageModel.default.isAvailable else { return labels }
  //
  //     let session = LanguageModelSession(instructions:
  //         "You normalize food ingredient names. Convert to singular, common English names.")
  //     let prompt = "Normalize these food labels: \(labels.joined(separator: ", ")). Filter out non-food items."
  //     let response = try await session.respond(to: prompt, generating: [NormalizedIngredient].self)
  //     return response.content.filter(\.isFood).map(\.name)
  // }

  // MARK: - Public API

  /// Normalize labels using AI if available, otherwise return as-is.
  /// The IngredientLexicon handles basic normalization regardless.
  static func enhancedNormalize(_ labels: [String]) async -> [String] {
    // When building with iOS 26 SDK, uncomment:
    // if #available(iOS 26, macOS 26, *) {
    //     if let normalized = try? await aiNormalize(labels) {
    //         return normalized
    //     }
    // }
    return labels
  }
}
