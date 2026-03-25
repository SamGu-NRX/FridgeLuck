import Foundation
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "GeminiCloudAgent")

struct CloudReverseScanRanking: Sendable {
  let recipeID: Int64
  let confidenceScore: Double
  let reason: String
}

/// Lightweight Gemini cloud client for structured JSON outputs.
/// API key is read from environment or Info.plist; never hardcoded.
final class GeminiCloudAgent: @unchecked Sendable {
  struct Config: Sendable {
    let apiKey: String?
    let modelName: String
    let backendBaseURL: URL?

    static func load() -> Config? {
      let env = ProcessInfo.processInfo.environment
      let envBackendBaseURL = normalizedURL(env["GEMINI_BACKEND_BASE_URL"])
      let envKey = normalized(env["GEMINI_API_KEY"])
      let envModel = normalized(env["GEMINI_MODEL_NAME"]) ?? "gemini-3-flash-preview"

      let plistBackendBaseURL = normalizedURL(
        Bundle.main.object(forInfoDictionaryKey: "GEMINI_BACKEND_BASE_URL") as? String
      )
      let plistKey = normalized(
        Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String)
      let plistModel =
        normalized(Bundle.main.object(forInfoDictionaryKey: "GEMINI_MODEL_NAME") as? String)
        ?? envModel

      let backendBaseURL = envBackendBaseURL ?? plistBackendBaseURL
      let apiKey = envKey ?? plistKey

      guard backendBaseURL != nil || apiKey != nil else {
        return nil
      }

      return Config(
        apiKey: apiKey,
        modelName: envModel.isEmpty ? plistModel : envModel,
        backendBaseURL: backendBaseURL
      )
    }

    private static func normalized(_ value: String?) -> String? {
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedURL(_ value: String?) -> URL? {
      guard let normalized = normalized(value) else { return nil }
      return URL(string: normalized)
    }
  }

  private let config: Config?
  private let session: URLSession

  init(config: Config? = Config.load(), session: URLSession = .shared) {
    self.config = config
    self.session = session
    if let config {
      logger.info(
        "Initialized cloud agent. model=\(config.modelName, privacy: .public), backendBaseURL=\(config.backendBaseURL?.absoluteString ?? "-", privacy: .public), hasApiKey=\(config.apiKey != nil, privacy: .public)"
      )
    } else {
      logger.notice(
        "Gemini cloud agent not configured. Set GEMINI_BACKEND_BASE_URL or GEMINI_API_KEY.")
    }
  }

  var isConfigured: Bool {
    guard let config else { return false }
    return config.backendBaseURL != nil || config.apiKey != nil
  }

  func generateRecipe(
    ingredientNames: [String],
    dietaryRestrictions: [String],
    photoJPEGData: Data?,
    scanConfidenceScore: Double?
  ) async throws -> GeneratedRecipeResult? {
    guard let config else {
      logger.notice("Skipping cloud recipe generation: missing config.")
      return nil
    }
    guard !ingredientNames.isEmpty else {
      logger.debug("Skipping cloud recipe generation: no ingredient names.")
      return nil
    }

    logger.info(
      "Cloud recipe generation request. ingredients=\(ingredientNames.count, privacy: .public), restrictions=\(dietaryRestrictions.count, privacy: .public), hasPhoto=\(photoJPEGData != nil, privacy: .public), scanConfidence=\(scanConfidenceScore ?? -1, privacy: .public)"
    )

    if config.backendBaseURL != nil {
      do {
        if let backendRecipe = try await generateRecipeViaBackend(
          config: config,
          ingredientNames: ingredientNames,
          dietaryRestrictions: dietaryRestrictions,
          photoJPEGData: photoJPEGData,
          scanConfidenceScore: scanConfidenceScore
        ) {
          logger.info("Cloud recipe generation succeeded via backend.")
          return backendRecipe
        }
      } catch {
        logger.error(
          "Backend recipe generation failed: \(error.localizedDescription, privacy: .public)")
      }

      if config.apiKey == nil {
        logger.notice("No direct Gemini API key available; backend fallback exhausted.")
        return nil
      }
    }

    let ingredients = ingredientNames.joined(separator: ", ")
    let restrictions =
      dietaryRestrictions.isEmpty
      ? "none"
      : dietaryRestrictions.joined(separator: ", ")

    let prompt = """
      You are a practical home cooking assistant for a smart-fridge app.
      Return only valid JSON using this schema:
      {
        "title": string,
        "time_minutes": integer,
        "servings": integer,
        "instructions": string,
        "estimated_calories_per_serving": integer
      }

      Inputs:
      - ingredients_from_scan: \(ingredients)
      - dietary_restrictions: \(restrictions)
      - scan_confidence_score: \(scanConfidenceScore ?? 0.0)
      - has_photo: \(photoJPEGData != nil)

      Constraints:
      - Use scanned ingredients first.
      - Keep instructions concise and executable.
      - Keep calories realistic.
      """

    guard let text = try await generateJSONText(prompt: prompt, imageJPEGData: photoJPEGData) else {
      logger.error("Cloud recipe generation failed: empty text response.")
      return nil
    }

    guard let payload = decodeJSON(RecipePayload.self, from: text) else {
      logger.error("Cloud recipe generation failed: JSON decode mismatch.")
      return nil
    }

    logger.info(
      "Cloud recipe generation succeeded. title=\(payload.title, privacy: .public), time=\(payload.timeMinutes, privacy: .public), servings=\(payload.servings, privacy: .public)"
    )

    return GeneratedRecipeResult(
      title: payload.title,
      timeMinutes: max(5, payload.timeMinutes),
      servings: max(1, payload.servings),
      instructions: payload.instructions,
      estimatedCaloriesPerServing: max(50, payload.estimatedCaloriesPerServing),
      isAIGenerated: true
    )
  }

  func rankReverseScanCandidates(
    detections: [Detection],
    candidates: [ReverseScanRecipeCandidate],
    photoJPEGData: Data?
  ) async throws -> [CloudReverseScanRanking]? {
    guard let config else {
      logger.notice("Skipping cloud reverse-scan ranking: missing config.")
      return nil
    }
    guard !detections.isEmpty, !candidates.isEmpty else {
      logger.debug(
        "Skipping cloud reverse-scan ranking: detections=\(detections.count, privacy: .public), candidates=\(candidates.count, privacy: .public)"
      )
      return nil
    }

    logger.info(
      "Cloud reverse-scan ranking request. detections=\(detections.count, privacy: .public), candidates=\(candidates.count, privacy: .public), hasPhoto=\(photoJPEGData != nil, privacy: .public)"
    )

    if config.backendBaseURL != nil {
      do {
        if let backendRankings = try await rankReverseScanViaBackend(
          config: config,
          detections: detections,
          candidates: candidates,
          photoJPEGData: photoJPEGData
        ) {
          logger.info("Cloud reverse-scan ranking succeeded via backend.")
          return backendRankings
        }
      } catch {
        logger.error(
          "Backend reverse-scan ranking failed: \(error.localizedDescription, privacy: .public)")
      }

      if config.apiKey == nil {
        logger.notice("No direct Gemini API key available; backend fallback exhausted.")
        return nil
      }
    }

    let detectionSummary = detections.prefix(16).map {
      "\($0.label):\(Int(($0.confidence * 100).rounded()))"
    }.joined(separator: ", ")

    let candidateSummary = candidates.prefix(8).compactMap { candidate -> String? in
      guard let recipeID = candidate.recipe.recipe.id else { return nil }
      return
        "id=\(recipeID), title=\(candidate.recipe.recipe.title), local_conf=\(candidate.confidenceScore), missing_required=\(candidate.recipe.missingRequiredCount)"
    }.joined(separator: "\n")

    guard !candidateSummary.isEmpty else { return nil }

    let prompt = """
      You are ranking recipe candidates for reverse meal scan.
      Return only valid JSON using this schema:
      {
        "rankings": [
          {
            "recipe_id": integer,
            "confidence_score": number,
            "reason": string
          }
        ]
      }

      Inputs:
      detections: \(detectionSummary)
      candidates:
      \(candidateSummary)

      Rules:
      - confidence_score must be in [0,1].
      - Prefer lower missing_required and better alignment with detections.
      - Keep reason short.
      """

    guard let text = try await generateJSONText(prompt: prompt, imageJPEGData: photoJPEGData) else {
      logger.error("Cloud reverse-scan ranking failed: empty text response.")
      return nil
    }

    guard let payload = decodeJSON(RankingPayload.self, from: text) else {
      logger.error("Cloud reverse-scan ranking failed: JSON decode mismatch.")
      return nil
    }

    logger.info(
      "Cloud reverse-scan ranking succeeded. ranked=\(payload.rankings.count, privacy: .public)")

    return payload.rankings.map {
      CloudReverseScanRanking(
        recipeID: $0.recipeID,
        confidenceScore: max(0, min($0.confidenceScore, 1.0)),
        reason: $0.reason
      )
    }
  }

  private func generateJSONText(
    prompt: String,
    imageJPEGData: Data?
  ) async throws -> String? {
    guard let config, let apiKey = config.apiKey else { return nil }
    let requestID = UUID().uuidString

    let endpoint = URL(
      string:
        "https://generativelanguage.googleapis.com/v1beta/models/\(config.modelName):generateContent"
    )!

    var parts: [GeminiPart] = [.text(prompt)]
    if let imageJPEGData {
      parts.append(
        .inlineData(mimeType: "image/jpeg", dataBase64: imageJPEGData.base64EncodedString()))
    }

    let payload = GenerateContentRequest(
      contents: [GeminiContent(parts: parts)],
      generationConfig: GeminiGenerationConfig(responseMimeType: "application/json")
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = try JSONEncoder().encode(payload)

    logger.debug(
      "Dispatching Gemini request id=\(requestID, privacy: .public), model=\(config.modelName, privacy: .public), hasInlineImage=\(imageJPEGData != nil, privacy: .public)"
    )
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      logger.error("Gemini request id=\(requestID, privacy: .public) failed: non-HTTP response.")
      return nil
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let responseText = String(data: data, encoding: .utf8) ?? ""
      let trimmed = String(responseText.prefix(280))
      logger.error(
        "Gemini request id=\(requestID, privacy: .public) returned status=\(httpResponse.statusCode, privacy: .public), body=\(trimmed, privacy: .public)"
      )
      return nil
    }

    let decoded: GenerateContentResponse
    do {
      decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
    } catch {
      logger.error(
        "Gemini request id=\(requestID, privacy: .public) decode error: \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }

    logger.debug("Gemini request id=\(requestID, privacy: .public) succeeded.")
    return decoded.candidates?
      .first?
      .content?
      .parts?
      .compactMap(\.text)
      .joined(separator: "\n")
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
    let sanitized = sanitizeJSONBlock(text)
    guard let data = sanitized.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private func sanitizeJSONBlock(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") {
      return
        trimmed
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
  }

  private func generateRecipeViaBackend(
    config: Config,
    ingredientNames: [String],
    dietaryRestrictions: [String],
    photoJPEGData: Data?,
    scanConfidenceScore: Double?
  ) async throws -> GeneratedRecipeResult? {
    guard let baseURL = config.backendBaseURL else { return nil }
    let endpoint = baseURL.appendingPathComponent("v1/recipes/generate")

    let requestBody = BackendRecipeGenerateRequest(
      ingredientNames: ingredientNames,
      dietaryRestrictions: dietaryRestrictions,
      scanConfidenceScore: scanConfidenceScore,
      photoBase64JPEG: photoJPEGData?.base64EncodedString()
    )

    guard
      let response: BackendRecipeGenerateResponse = try await postJSON(
        url: endpoint,
        body: requestBody
      )
    else {
      return nil
    }

    return GeneratedRecipeResult(
      title: response.title,
      timeMinutes: max(5, response.timeMinutes),
      servings: max(1, response.servings),
      instructions: response.instructions,
      estimatedCaloriesPerServing: max(50, response.estimatedCaloriesPerServing),
      isAIGenerated: true
    )
  }

  private func rankReverseScanViaBackend(
    config: Config,
    detections: [Detection],
    candidates: [ReverseScanRecipeCandidate],
    photoJPEGData: Data?
  ) async throws -> [CloudReverseScanRanking]? {
    guard let baseURL = config.backendBaseURL else { return nil }
    let endpoint = baseURL.appendingPathComponent("v1/reverse-scan/rank")

    let candidatePayload = candidates.compactMap { candidate -> BackendReverseScanCandidate? in
      guard let recipeID = candidate.recipe.recipe.id else { return nil }
      return BackendReverseScanCandidate(
        recipeId: recipeID,
        title: candidate.recipe.recipe.title,
        localConfidence: candidate.confidenceScore,
        missingRequiredCount: candidate.recipe.missingRequiredCount
      )
    }

    guard !candidatePayload.isEmpty else { return nil }

    let requestBody = BackendReverseScanRankRequest(
      detections: detections.map {
        BackendReverseScanDetection(
          label: $0.label,
          confidence: Double(max(0, min($0.confidence, 1.0)))
        )
      },
      candidates: candidatePayload,
      photoBase64JPEG: photoJPEGData?.base64EncodedString()
    )

    guard
      let response: BackendReverseScanRankResponse = try await postJSON(
        url: endpoint,
        body: requestBody
      )
    else {
      return nil
    }

    return response.rankings.map {
      CloudReverseScanRanking(
        recipeID: $0.recipeId,
        confidenceScore: max(0, min($0.confidenceScore, 1.0)),
        reason: $0.reason
      )
    }
  }

  private func postJSON<Request: Encodable, Response: Decodable>(
    url: URL,
    body: Request
  ) async throws -> Response? {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else { return nil }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let responseText = String(data: data, encoding: .utf8) ?? ""
      logger.error(
        "Backend request failed. url=\(url.absoluteString, privacy: .public), status=\(httpResponse.statusCode, privacy: .public), body=\(String(responseText.prefix(280)), privacy: .public)"
      )
      return nil
    }

    if data.isEmpty { return nil }
    return try JSONDecoder().decode(Response.self, from: data)
  }
}

private struct GenerateContentRequest: Encodable {
  let contents: [GeminiContent]
  let generationConfig: GeminiGenerationConfig

  enum CodingKeys: String, CodingKey {
    case contents
    case generationConfig
  }
}

private struct GeminiContent: Encodable {
  let parts: [GeminiPart]
}

private struct GeminiGenerationConfig: Encodable {
  let responseMimeType: String

  enum CodingKeys: String, CodingKey {
    case responseMimeType
  }
}

private enum GeminiPart: Encodable {
  case text(String)
  case inlineData(mimeType: String, dataBase64: String)

  enum CodingKeys: String, CodingKey {
    case text
    case inlineData = "inline_data"
  }

  enum InlineDataCodingKeys: String, CodingKey {
    case mimeType = "mime_type"
    case data
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let value):
      try container.encode(value, forKey: .text)
    case .inlineData(let mimeType, let dataBase64):
      var inlineContainer = container.nestedContainer(
        keyedBy: InlineDataCodingKeys.self, forKey: .inlineData)
      try inlineContainer.encode(mimeType, forKey: .mimeType)
      try inlineContainer.encode(dataBase64, forKey: .data)
    }
  }
}

private struct GenerateContentResponse: Decodable {
  let candidates: [GenerateCandidate]?
}

private struct GenerateCandidate: Decodable {
  let content: GenerateCandidateContent?
}

private struct GenerateCandidateContent: Decodable {
  let parts: [GeneratePart]?
}

private struct GeneratePart: Decodable {
  let text: String?
}

private struct RecipePayload: Decodable {
  let title: String
  let timeMinutes: Int
  let servings: Int
  let instructions: String
  let estimatedCaloriesPerServing: Int

  enum CodingKeys: String, CodingKey {
    case title
    case timeMinutes = "time_minutes"
    case servings
    case instructions
    case estimatedCaloriesPerServing = "estimated_calories_per_serving"
  }
}

private struct RankingPayload: Decodable {
  let rankings: [RankingItem]
}

private struct RankingItem: Decodable {
  let recipeID: Int64
  let confidenceScore: Double
  let reason: String

  enum CodingKeys: String, CodingKey {
    case recipeID = "recipe_id"
    case confidenceScore = "confidence_score"
    case reason
  }
}

private struct BackendRecipeGenerateRequest: Encodable {
  let ingredientNames: [String]
  let dietaryRestrictions: [String]
  let scanConfidenceScore: Double?
  let photoBase64JPEG: String?
}

private struct BackendRecipeGenerateResponse: Decodable {
  let title: String
  let timeMinutes: Int
  let servings: Int
  let instructions: String
  let estimatedCaloriesPerServing: Int
}

private struct BackendReverseScanRankRequest: Encodable {
  let detections: [BackendReverseScanDetection]
  let candidates: [BackendReverseScanCandidate]
  let photoBase64JPEG: String?
}

private struct BackendReverseScanDetection: Encodable {
  let label: String
  let confidence: Double
}

private struct BackendReverseScanCandidate: Encodable {
  let recipeId: Int64
  let title: String
  let localConfidence: Double
  let missingRequiredCount: Int
}

private struct BackendReverseScanRankResponse: Decodable {
  let rankings: [BackendReverseScanRankItem]
}

private struct BackendReverseScanRankItem: Decodable {
  let recipeId: Int64
  let confidenceScore: Double
  let reason: String
}
