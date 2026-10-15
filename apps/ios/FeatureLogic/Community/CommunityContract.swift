import Foundation

/// Wire types for the community contract (`docs/spec/community/contracts/`).
///
/// These are the exact structs the client sends and decodes: the publish sheet previews the
/// same struct the API client sends, so the preview can never drift from the payload
/// (community SPEC 8.2). Field names and shapes follow `contracts/schemas/` and the
/// examples in `contracts/examples/`; unit tests decode every example the app uses.
public enum CommunityContract {
  /// Canonical ISO-8601 UTC rendering used by the contract ("2026-10-15T18:40:00Z").
  /// `Date.ISO8601FormatStyle` is a Sendable value type, so a shared instance is
  /// concurrency-safe under Swift 6 strict checking (an `ISO8601DateFormatter` is not).
  private static let iso8601Style = Date.ISO8601FormatStyle()

  public static func iso8601(_ date: Date) -> String {
    iso8601Style.format(date)
  }

  public static func date(fromISO8601 value: String) -> Date? {
    try? iso8601Style.parse(value)
  }
}

// MARK: - RecipeRef

/// Where a referenced recipe came from (`common.schema.json` / RecipeRef).
public enum RecipeRefSource: String, Codable, Sendable, CaseIterable {
  case user
  case catalog
  case community
}

/// A pointer at one frozen revision of a recipe.
public struct RecipeRef: Codable, Sendable, Equatable, Hashable {
  public var source: RecipeRefSource
  public var id: String
  public var revision: Int

  public init(source: RecipeRefSource, id: String, revision: Int) {
    self.source = source
    self.id = id
    self.revision = revision
  }
}

// MARK: - Recipe content (recipe-content.schema.json)

/// Units the contract allows on an ingredient line.
public enum IngredientUnit: String, Codable, Sendable, CaseIterable {
  case gram = "g"
  case kilogram = "kg"
  case millilitre = "ml"
  case litre = "l"
  case teaspoon = "tsp"
  case tablespoon = "tbsp"
  case cup = "cup"
  case fluidOunce = "fl-oz"
  case piece = "piece"
  case clove = "clove"
  case pinch = "pinch"
  case can = "can"
}

/// One ingredient line. `quantity == nil` means quantity unknown — never an invented mass.
/// Encodes every contract key, using null for absent optionals, matching the shape of the
/// contract examples exactly (community SPEC 8.2).
public struct IngredientLine: Codable, Sendable, Equatable, Hashable {
  public var name: String
  public var quantity: Double?
  public var unit: IngredientUnit?
  public var preparation: String?
  public var fdcId: Int?

  public init(
    name: String,
    quantity: Double? = nil,
    unit: IngredientUnit? = nil,
    preparation: String? = nil,
    fdcId: Int? = nil
  ) {
    self.name = name
    self.quantity = quantity
    self.unit = unit
    self.preparation = preparation
    self.fdcId = fdcId
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    if let quantity {
      try container.encode(quantity, forKey: .quantity)
    } else {
      try container.encodeNil(forKey: .quantity)
    }
    if let unit {
      try container.encode(unit, forKey: .unit)
    } else {
      try container.encodeNil(forKey: .unit)
    }
    if let preparation {
      try container.encode(preparation, forKey: .preparation)
    } else {
      try container.encodeNil(forKey: .preparation)
    }
    if let fdcId {
      try container.encode(fdcId, forKey: .fdcId)
    } else {
      try container.encodeNil(forKey: .fdcId)
    }
  }
}

/// One step. `timerMinutes` only when the step has a natural timer — never a fake one.
public struct RecipeStep: Codable, Sendable, Equatable, Hashable {
  public var text: String
  public var timerMinutes: Int?

  public init(text: String, timerMinutes: Int? = nil) {
    self.text = text
    self.timerMinutes = timerMinutes
  }

  enum CodingKeys: String, CodingKey {
    case text, timerMinutes
  }
}

/// The full content of one recipe revision: exactly what leaves the phone when a recipe is
/// published or a cook is shared — nothing else (recipe-content.schema.json, SPEC 2.3).
public struct RecipeRevisionContent: Codable, Sendable, Equatable, Hashable {
  public var title: String
  public var description: String?
  public var servings: Int
  public var timeMinutes: Int?
  public var ingredientLines: [IngredientLine]
  public var steps: [RecipeStep]
  public var equipment: [String]
  public var dietaryTags: [String]

  public init(
    title: String,
    description: String? = nil,
    servings: Int,
    timeMinutes: Int? = nil,
    ingredientLines: [IngredientLine],
    steps: [RecipeStep],
    equipment: [String] = [],
    dietaryTags: [String] = []
  ) {
    self.title = title
    self.description = description
    self.servings = servings
    self.timeMinutes = timeMinutes
    self.ingredientLines = ingredientLines
    self.steps = steps
    self.equipment = equipment
    self.dietaryTags = dietaryTags
  }

  enum CodingKeys: String, CodingKey {
    case title
    case description
    case servings
    case timeMinutes
    case ingredientLines
    case steps
    case equipment
    case dietaryTags
  }
}

// MARK: - Rights declaration

/// The two author attestations from the publish flow (SPEC 2.3, step 2). Stored verbatim on
/// the publication document server-side; readers never receive it.
public struct RecipeRightsDeclaration: Codable, Sendable, Equatable, Hashable {
  public var ownRights: Bool
  public var noPersonalData: Bool

  public init(ownRights: Bool, noPersonalData: Bool) {
    self.ownRights = ownRights
    self.noPersonalData = noPersonalData
  }

  enum CodingKeys: String, CodingKey {
    case ownRights, noPersonalData
  }
}

// MARK: - Publication (publication.schema.json)

/// Allergen tags the screening pipeline computes (`common.schema.json` / AllergenTag).
public enum AllergenTag: String, Codable, Sendable, CaseIterable, Hashable {
  case milk
  case eggs
  case fish
  case shellfish
  case treeNuts = "tree-nuts"
  case peanuts
  case wheat
  case soy
  case sesame
  case mustard
  case sulphites
  case unknownContents = "unknown-contents"
}

/// Server-side publication state (PR #104 states). Only `published` is served in Explore.
public enum PublicationState: String, Codable, Sendable, Hashable {
  case published
  case queued
  case rejected
  case withdrawn
}

/// A published user-recipe revision, as the server returns it (reader view; the rights
/// declaration is never served to readers).
public struct Publication: Codable, Sendable, Equatable, Hashable {
  public var publicationId: String
  public var recipeRef: RecipeRef
  public var content: RecipeRevisionContent
  public var authorDisplayName: String
  public var allergenTags: [AllergenTag]
  public var state: PublicationState
  /// ISO-8601 UTC string, exactly as the contract carries it.
  public var publishedAt: String
  public var withdrawnAt: String?
  public var flaggedTag: AllergenTag?
  public var challengeId: String?

  public init(
    publicationId: String,
    recipeRef: RecipeRef,
    content: RecipeRevisionContent,
    authorDisplayName: String,
    allergenTags: [AllergenTag],
    state: PublicationState,
    publishedAt: String,
    withdrawnAt: String? = nil,
    flaggedTag: AllergenTag? = nil,
    challengeId: String? = nil
  ) {
    self.publicationId = publicationId
    self.recipeRef = recipeRef
    self.content = content
    self.authorDisplayName = authorDisplayName
    self.allergenTags = allergenTags
    self.state = state
    self.publishedAt = publishedAt
    self.withdrawnAt = withdrawnAt
    self.flaggedTag = flaggedTag
    self.challengeId = challengeId
  }

  enum CodingKeys: String, CodingKey {
    case publicationId
    case recipeRef
    case content
    case authorDisplayName
    case allergenTags
    case state
    case publishedAt
    case withdrawnAt
    case flaggedTag
    case challengeId
  }
}

/// `publication-list.schema.json`.
public struct PublicationList: Codable, Sendable, Equatable {
  public var publications: [Publication]

  public init(publications: [Publication]) {
    self.publications = publications
  }
}

// MARK: - Requests

/// Body of `POST /v1/publications`. `operationId` is client-generated (UUID) so the server
/// can deduplicate replays of the same outbox item (SPEC 8.3).
public struct CreatePublicationRequest: Codable, Sendable, Equatable {
  public var operationId: String
  public var recipeRef: RecipeRef
  public var content: RecipeRevisionContent
  public var declaration: RecipeRightsDeclaration
  public var challengeId: String?

  public init(
    operationId: String,
    recipeRef: RecipeRef,
    content: RecipeRevisionContent,
    declaration: RecipeRightsDeclaration,
    challengeId: String? = nil
  ) {
    self.operationId = operationId
    self.recipeRef = recipeRef
    self.content = content
    self.declaration = declaration
    self.challengeId = challengeId
  }

  enum CodingKeys: String, CodingKey {
    case operationId, recipeRef, content, declaration, challengeId
  }
}

/// Encodes the request in the contract's wire form: every field present, with
/// `challengeId: null` when absent — byte-shape parity with `contracts/examples/` (SPEC 8.2).
extension CreatePublicationRequest {
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(operationId, forKey: .operationId)
    try container.encode(recipeRef, forKey: .recipeRef)
    try container.encode(content, forKey: .content)
    try container.encode(declaration, forKey: .declaration)
    if let challengeId {
      try container.encode(challengeId, forKey: .challengeId)
    } else {
      try container.encodeNil(forKey: .challengeId)
    }
  }
}

/// Local outbox payload for a withdraw operation. On the wire a withdraw is
/// `DELETE /v1/publications/{publicationId}` with no body.
public struct WithdrawPublicationRequest: Codable, Sendable, Equatable {
  public var publicationId: String

  public init(publicationId: String) {
    self.publicationId = publicationId
  }
}
