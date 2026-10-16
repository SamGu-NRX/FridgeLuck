import Foundation

/// Challenges wire types (`contracts/schemas/challenge.schema.json`,
/// `challenge-entry.schema.json`, and the CreateEntryRequest / CastVoteRequest bodies):
/// weekly community bakes with time-gated windows and anonymous votes
/// (community SPEC 4, 6.3).

// MARK: - Challenge (challenge.schema.json)

public enum CommunityChallengeType: String, Codable, Sendable, Hashable, CaseIterable {
  case battle
  case useItUp = "use-it-up"
  case budget
  case seasonal
  case foodBank = "food-bank"
  case campus
}

public enum CommunityChallengeStatus: String, Codable, Sendable, Hashable, CaseIterable {
  case draft
  case open
  case voting
  case closed
}

/// One ingredient the challenge asks cooks to use up.
public struct CommunityChallengeItem: Codable, Sendable, Equatable, Hashable {
  public var fdcId: Int
  public var name: String
  public var quantityText: String?

  public init(fdcId: Int, name: String, quantityText: String? = nil) {
    self.fdcId = fdcId
    self.name = name
    self.quantityText = quantityText
  }

  enum CodingKeys: String, CodingKey {
    case fdcId, name, quantityText
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fdcId = try container.decode(Int.self, forKey: .fdcId)
    name = try container.decode(String.self, forKey: .name)
    quantityText = try container.decodeIfPresent(String.self, forKey: .quantityText)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(fdcId, forKey: .fdcId)
    try container.encode(name, forKey: .name)
    if let quantityText {
      try container.encode(quantityText, forKey: .quantityText)
    } else {
      try container.encodeNil(forKey: .quantityText)
    }
  }
}

public struct CommunityChallengeScope: Codable, Sendable, Equatable, Hashable {
  public var kind: String
  public var schoolKey: String?

  public init(kind: String, schoolKey: String? = nil) {
    self.kind = kind
    self.schoolKey = schoolKey
  }

  enum CodingKeys: String, CodingKey {
    case kind, schoolKey
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(String.self, forKey: .kind)
    schoolKey = try container.decodeIfPresent(String.self, forKey: .schoolKey)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    if let schoolKey {
      try container.encode(schoolKey, forKey: .schoolKey)
    } else {
      try container.encodeNil(forKey: .schoolKey)
    }
  }
}

/// A challenge as one viewer sees it (SPEC 4.2). `resolvedItems` is the server-resolved
/// ingredient list for a pack-based challenge; `myEntryId` / `myVoteEntryId` are set only
/// for this viewer's own actions and are null in everyone else's view. One entry and one
/// vote per account.
public struct CommunityChallenge: Codable, Sendable, Equatable, Hashable {
  public var challengeId: String
  public var name: String
  public var brief: String
  public var type: CommunityChallengeType
  public var status: CommunityChallengeStatus
  public var opensAt: String
  public var entryClosesAt: String
  public var votingClosesAt: String
  public var entryCount: Int
  public var resolvedItems: [CommunityChallengeItem]?
  public var packId: String?
  public var myEntryId: String?
  public var myVoteEntryId: String?
  public var scope: CommunityChallengeScope?

  public init(
    challengeId: String, name: String, brief: String, type: CommunityChallengeType,
    status: CommunityChallengeStatus, opensAt: String, entryClosesAt: String,
    votingClosesAt: String,
    entryCount: Int, resolvedItems: [CommunityChallengeItem]? = nil, packId: String? = nil,
    myEntryId: String? = nil, myVoteEntryId: String? = nil, scope: CommunityChallengeScope? = nil
  ) {
    self.challengeId = challengeId
    self.name = name
    self.brief = brief
    self.type = type
    self.status = status
    self.opensAt = opensAt
    self.entryClosesAt = entryClosesAt
    self.votingClosesAt = votingClosesAt
    self.entryCount = entryCount
    self.resolvedItems = resolvedItems
    self.packId = packId
    self.myEntryId = myEntryId
    self.myVoteEntryId = myVoteEntryId
    self.scope = scope
  }

  enum CodingKeys: String, CodingKey {
    case challengeId, name, brief, type, status, opensAt, entryClosesAt, votingClosesAt
    case entryCount, resolvedItems, packId, myEntryId, myVoteEntryId, scope
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    challengeId = try container.decode(String.self, forKey: .challengeId)
    name = try container.decode(String.self, forKey: .name)
    brief = try container.decode(String.self, forKey: .brief)
    type = try container.decode(CommunityChallengeType.self, forKey: .type)
    status = try container.decode(CommunityChallengeStatus.self, forKey: .status)
    opensAt = try container.decode(String.self, forKey: .opensAt)
    entryClosesAt = try container.decode(String.self, forKey: .entryClosesAt)
    votingClosesAt = try container.decode(String.self, forKey: .votingClosesAt)
    entryCount = try container.decode(Int.self, forKey: .entryCount)
    resolvedItems = try container.decodeIfPresent(
      [CommunityChallengeItem].self, forKey: .resolvedItems)
    packId = try container.decodeIfPresent(String.self, forKey: .packId)
    myEntryId = try container.decodeIfPresent(String.self, forKey: .myEntryId)
    myVoteEntryId = try container.decodeIfPresent(String.self, forKey: .myVoteEntryId)
    scope = try container.decodeIfPresent(CommunityChallengeScope.self, forKey: .scope)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(challengeId, forKey: .challengeId)
    try container.encode(name, forKey: .name)
    try container.encode(brief, forKey: .brief)
    try container.encode(type, forKey: .type)
    try container.encode(status, forKey: .status)
    try container.encode(opensAt, forKey: .opensAt)
    try container.encode(entryClosesAt, forKey: .entryClosesAt)
    try container.encode(votingClosesAt, forKey: .votingClosesAt)
    try container.encode(entryCount, forKey: .entryCount)
    if let resolvedItems {
      try container.encode(resolvedItems, forKey: .resolvedItems)
    } else {
      try container.encodeNil(forKey: .resolvedItems)
    }
    if let packId {
      try container.encode(packId, forKey: .packId)
    } else {
      try container.encodeNil(forKey: .packId)
    }
    if let myEntryId {
      try container.encode(myEntryId, forKey: .myEntryId)
    } else {
      try container.encodeNil(forKey: .myEntryId)
    }
    if let myVoteEntryId {
      try container.encode(myVoteEntryId, forKey: .myVoteEntryId)
    } else {
      try container.encodeNil(forKey: .myVoteEntryId)
    }
    if let scope {
      try container.encode(scope, forKey: .scope)
    } else {
      try container.encodeNil(forKey: .scope)
    }
  }
}

public struct CommunityChallengeList: Codable, Sendable, Equatable {
  public var challenges: [CommunityChallenge]

  public init(challenges: [CommunityChallenge]) {
    self.challenges = challenges
  }

  enum CodingKeys: String, CodingKey {
    case challenges
  }
}

// MARK: - Entry (challenge-entry.schema.json)

/// Moderation state of an entry as its viewer sees it (SPEC 6.4): reported entries read as
/// `in_review` to their author while a case is open, and are simply absent for others.
public enum CommunityEntryState: String, Codable, Sendable, Hashable, CaseIterable {
  case visible
  case inReview = "in_review"
}

/// One challenge entry. `voteCount` is null until voting closes — no live tallies (SPEC 4.3);
/// the client hides it defensively too (`CommunityChallengeRules`).
public struct CommunityChallengeEntry: Codable, Sendable, Equatable, Hashable {
  public var entryId: String
  public var challengeId: String
  public var recipeRef: RecipeRef
  public var title: String
  public var authorDisplayName: String
  public var note: String?
  public var createdAt: String
  public var state: CommunityEntryState
  public var voteCount: Int?

  public init(
    entryId: String, challengeId: String, recipeRef: RecipeRef, title: String,
    authorDisplayName: String, note: String? = nil, createdAt: String,
    state: CommunityEntryState = .visible, voteCount: Int? = nil
  ) {
    self.entryId = entryId
    self.challengeId = challengeId
    self.recipeRef = recipeRef
    self.title = title
    self.authorDisplayName = authorDisplayName
    self.note = note
    self.createdAt = createdAt
    self.state = state
    self.voteCount = voteCount
  }

  enum CodingKeys: String, CodingKey {
    case entryId, challengeId, recipeRef, title, authorDisplayName, note, createdAt, state,
      voteCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    entryId = try container.decode(String.self, forKey: .entryId)
    challengeId = try container.decode(String.self, forKey: .challengeId)
    recipeRef = try container.decode(RecipeRef.self, forKey: .recipeRef)
    title = try container.decode(String.self, forKey: .title)
    authorDisplayName = try container.decode(String.self, forKey: .authorDisplayName)
    note = try container.decodeIfPresent(String.self, forKey: .note)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    state = try container.decode(CommunityEntryState.self, forKey: .state)
    voteCount = try container.decodeIfPresent(Int.self, forKey: .voteCount)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entryId, forKey: .entryId)
    try container.encode(challengeId, forKey: .challengeId)
    try container.encode(recipeRef, forKey: .recipeRef)
    try container.encode(title, forKey: .title)
    try container.encode(authorDisplayName, forKey: .authorDisplayName)
    if let note {
      try container.encode(note, forKey: .note)
    } else {
      try container.encodeNil(forKey: .note)
    }
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(state, forKey: .state)
    if let voteCount {
      try container.encode(voteCount, forKey: .voteCount)
    } else {
      try container.encodeNil(forKey: .voteCount)
    }
  }
}

/// Detail of `GET /v1/challenges/{challengeId}`: the challenge plus its entries.
public struct CommunityChallengeDetail: Codable, Sendable, Equatable {
  public var challenge: CommunityChallenge
  public var entries: [CommunityChallengeEntry]

  public init(challenge: CommunityChallenge, entries: [CommunityChallengeEntry]) {
    self.challenge = challenge
    self.entries = entries
  }

  enum CodingKeys: String, CodingKey {
    case challenge, entries
  }
}

// MARK: - Requests

/// Body of `POST /v1/challenges/{challengeId}/entries` (CreateEntryRequest). `operationId`
/// is client-generated (UUID) for outbox replay dedup (SPEC 8.3); `note` is optional and
/// runs the personal-data screen (SPEC 6.5).
public struct CommunityCreateEntryRequest: Codable, Sendable, Equatable, Hashable {
  public var operationId: String
  public var recipeRef: RecipeRef
  public var note: String?

  public init(operationId: String, recipeRef: RecipeRef, note: String? = nil) {
    self.operationId = operationId
    self.recipeRef = recipeRef
    self.note = note
  }

  enum CodingKeys: String, CodingKey {
    case operationId, recipeRef, note
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    operationId = try container.decode(String.self, forKey: .operationId)
    recipeRef = try container.decode(RecipeRef.self, forKey: .recipeRef)
    note = try container.decodeIfPresent(String.self, forKey: .note)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(operationId, forKey: .operationId)
    try container.encode(recipeRef, forKey: .recipeRef)
    if let note {
      try container.encode(note, forKey: .note)
    } else {
      try container.encodeNil(forKey: .note)
    }
  }
}

/// Body of `PUT /v1/challenges/{challengeId}/vote` (CastVoteRequest). Votes are anonymous;
/// casting again moves the vote; `DELETE` removes it (SPEC 4.3).
public struct CommunityCastVoteRequest: Codable, Sendable, Equatable, Hashable {
  public var entryId: String

  public init(entryId: String) {
    self.entryId = entryId
  }

  enum CodingKeys: String, CodingKey {
    case entryId
  }
}
