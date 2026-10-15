import Foundation

/// The publish preview: the exact struct the client will send, plus display-only context
/// for the "What leaves your phone" sheet (SPEC 2.3 step 3, SPEC 8.2, SPEC 9.3).
///
/// The sheet renders `payload` — the same value the outbox queues and the API client sends —
/// so the preview can never drift from the wire. `authorDisplayName` is display context only
/// (the server attaches the account's display name to the publication document; the request
/// body itself carries no identity).
public struct SharePreview: Sendable, Equatable {
  /// The outgoing request body, byte-for-byte what `POST /v1/publications` receives.
  public let payload: CreatePublicationRequest
  /// Display context: the name that will appear on the publication. First name or chosen
  /// handle only — the account's Apple identity never appears (SPEC 6.1).
  public let authorDisplayName: String
  /// When true, the publish sheet shows "Will send when you're online." (SPEC 8.4).
  public let willQueueOffline: Bool

  /// The negatives stated on the sheet, in the same words as the spec.
  public static let neverSentCopy =
    "Never sent: your pantry, health information, taste profile, photos, or anything else about you."
}

/// Builds the share preview and the outgoing publication payload from one frozen revision.
///
/// The builder accepts only the fields the spec allows. Pantry, health profile, taste data,
/// exact cook times, photos, contact identifiers and device identifiers have no parameter on
/// any entry point, so they cannot reach the payload structurally; the redaction unit test
/// additionally asserts the encoded JSON contains only whitelisted keys.
public enum SharePreviewBuilder {
  /// Builds the preview from an already-frozen revision (the publish payload form).
  public static func preview(
    communityRecipeId: String,
    revision: Int,
    content: RecipeRevisionContent,
    declaration: RecipeRightsDeclaration,
    operationId: String,
    authorDisplayName: String,
    challengeId: String? = nil,
    willQueueOffline: Bool = false
  ) -> SharePreview {
    let payload = payload(
      communityRecipeId: communityRecipeId,
      revision: revision,
      content: content,
      declaration: declaration,
      operationId: operationId,
      challengeId: challengeId
    )
    return SharePreview(
      payload: payload,
      authorDisplayName: authorDisplayName,
      willQueueOffline: willQueueOffline
    )
  }

  /// Builds the outgoing request body — the single struct that is previewed and sent.
  public static func payload(
    communityRecipeId: String,
    revision: Int,
    content: RecipeRevisionContent,
    declaration: RecipeRightsDeclaration,
    operationId: String,
    challengeId: String? = nil
  ) -> CreatePublicationRequest {
    CreatePublicationRequest(
      operationId: operationId,
      recipeRef: RecipeRef(source: .user, id: communityRecipeId, revision: revision),
      content: content,
      declaration: declaration,
      challengeId: challengeId
    )
  }

  // MARK: - Whitelists (used by the redaction tests and the sheet's field list)

  /// Every key allowed at the top level of the outgoing request body.
  public static let allowedRequestKeys: Set<String> = [
    "operationId", "recipeRef", "content", "declaration", "challengeId",
  ]

  /// Every key allowed inside `recipeRef`.
  public static let allowedRecipeRefKeys: Set<String> = ["source", "id", "revision"]

  /// Every key allowed inside `declaration`.
  public static let allowedDeclarationKeys: Set<String> = ["ownRights", "noPersonalData"]

  /// Every key allowed inside `content` — the revision content, nothing else.
  public static let allowedContentKeys: Set<String> = [
    "title", "description", "servings", "timeMinutes", "ingredientLines", "steps", "equipment",
    "dietaryTags",
  ]

  /// Every key allowed on one ingredient line.
  public static let allowedIngredientLineKeys: Set<String> = [
    "name", "quantity", "unit", "preparation", "fdcId",
  ]

  /// Every key allowed on one step.
  public static let allowedStepKeys: Set<String> = ["text", "timerMinutes"]

  /// Returns every encoded key that is not in the whitelist, walking the whole payload.
  /// Empty means the payload carries exactly what the spec allows.
  public static func forbiddenKeys(in payload: CreatePublicationRequest) -> [String] {
    guard
      let data = try? JSONEncoder().encode(payload),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return ["<unencodable>"]
    }
    var forbidden: [String] = []
    walk(
      object: object,
      allowed: allowedRequestKeys,
      path: "",
      forbidden: &forbidden)
    return forbidden
  }

  private static func walk(
    object: [String: Any],
    allowed: Set<String>,
    path: String,
    forbidden: inout [String]
  ) {
    for (key, value) in object {
      let fullPath = path.isEmpty ? key : "\(path).\(key)"
      if !allowed.contains(key) {
        forbidden.append(fullPath)
      }
      switch value {
      case let nested as [String: Any]:
        var nestedAllowed: Set<String> = []
        if key == "content" {
          nestedAllowed = allowedContentKeys
        } else if key == "declaration" {
          nestedAllowed = allowedDeclarationKeys
        } else if key == "recipeRef" {
          nestedAllowed = allowedRecipeRefKeys
        }
        walk(object: nested, allowed: nestedAllowed, path: fullPath, forbidden: &forbidden)
      case let lines as [[String: Any]]:
        for (index, line) in lines.enumerated() {
          let lineAllowed: Set<String>
          if key == "ingredientLines" {
            lineAllowed = allowedIngredientLineKeys
          } else if key == "steps" {
            lineAllowed = allowedStepKeys
          } else {
            lineAllowed = []
          }
          for lineKey in line.keys where !lineAllowed.contains(lineKey) {
            forbidden.append("\(fullPath)[\(index)].\(lineKey)")
          }
        }
      default:
        break
      }
    }
  }
}
