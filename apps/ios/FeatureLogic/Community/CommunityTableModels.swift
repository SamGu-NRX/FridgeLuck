import Foundation

/// Tables wire types (`contracts/schemas/table.schema.json`, `table-invite.schema.json`,
/// `table-join.schema.json`, `table-card.schema.json`, `shared-cook.schema.json`,
/// `block-list.schema.json`, `report.schema.json`): cooking groups of 2–8, owner-approved
/// invites, shared cooks as cards, and the blocks/reports machinery underneath
/// (community SPEC 5, 6.3, 6.4).

// MARK: - Table (table.schema.json)

public enum CommunityTableRole: String, Codable, Sendable, Hashable, CaseIterable {
  case owner
  case member
}

/// A member of a Table. Account ids are visible to members (blocks and removal need them);
/// everything else about a member is their display name (SPEC 5.4).
public struct CommunityTableMember: Codable, Sendable, Equatable, Hashable {
  public var accountId: String
  public var displayName: String
  public var role: CommunityTableRole
  public var joinedAt: String?

  public init(
    accountId: String, displayName: String, role: CommunityTableRole, joinedAt: String? = nil
  ) {
    self.accountId = accountId
    self.displayName = displayName
    self.role = role
    self.joinedAt = joinedAt
  }

  enum CodingKeys: String, CodingKey {
    case accountId, displayName, role, joinedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountId = try container.decode(String.self, forKey: .accountId)
    displayName = try container.decode(String.self, forKey: .displayName)
    role = try container.decode(CommunityTableRole.self, forKey: .role)
    joinedAt = try container.decodeIfPresent(String.self, forKey: .joinedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountId, forKey: .accountId)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(role, forKey: .role)
    if let joinedAt {
      try container.encode(joinedAt, forKey: .joinedAt)
    } else {
      try container.encodeNil(forKey: .joinedAt)
    }
  }
}

public enum CommunityInviteState: String, Codable, Sendable, Hashable, CaseIterable {
  case pending, approved, revoked, expired, declined
}

/// Owner view of one invite row (SPEC 5.1). `requestedByDisplayName` is the joiner's ask.
public struct CommunityTableInviteSummary: Codable, Sendable, Equatable, Hashable {
  public var inviteId: String
  public var requestedByDisplayName: String?
  public var state: CommunityInviteState
  public var expiresAt: String

  public init(
    inviteId: String, requestedByDisplayName: String?, state: CommunityInviteState,
    expiresAt: String
  ) {
    self.inviteId = inviteId
    self.requestedByDisplayName = requestedByDisplayName
    self.state = state
    self.expiresAt = expiresAt
  }

  enum CodingKeys: String, CodingKey {
    case inviteId, requestedByDisplayName, state, expiresAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inviteId = try container.decode(String.self, forKey: .inviteId)
    requestedByDisplayName = try container.decodeIfPresent(
      String.self, forKey: .requestedByDisplayName)
    state = try container.decode(CommunityInviteState.self, forKey: .state)
    expiresAt = try container.decode(String.self, forKey: .expiresAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(inviteId, forKey: .inviteId)
    if let requestedByDisplayName {
      try container.encode(requestedByDisplayName, forKey: .requestedByDisplayName)
    } else {
      try container.encodeNil(forKey: .requestedByDisplayName)
    }
    try container.encode(state, forKey: .state)
    try container.encode(expiresAt, forKey: .expiresAt)
  }
}

/// A private group of 2–8 (SPEC 5.1). `pendingInvites` is owner view only; absent decodes as
/// an empty list and always re-encodes (the example shape).
public struct CommunityTable: Codable, Sendable, Equatable, Hashable {
  public var tableId: String
  public var name: String
  public var createdAt: String
  public var members: [CommunityTableMember]
  public var pendingInvites: [CommunityTableInviteSummary]?

  public init(
    tableId: String, name: String, createdAt: String,
    members: [CommunityTableMember], pendingInvites: [CommunityTableInviteSummary]? = []
  ) {
    self.tableId = tableId
    self.name = name
    self.createdAt = createdAt
    self.members = members
    self.pendingInvites = pendingInvites
  }

  enum CodingKeys: String, CodingKey {
    case tableId, name, createdAt, members, pendingInvites
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tableId = try container.decode(String.self, forKey: .tableId)
    name = try container.decode(String.self, forKey: .name)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    members = try container.decode([CommunityTableMember].self, forKey: .members)
    pendingInvites = try container.decodeIfPresent(
      [CommunityTableInviteSummary].self, forKey: .pendingInvites)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(tableId, forKey: .tableId)
    try container.encode(name, forKey: .name)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(members, forKey: .members)
    try container.encode(pendingInvites ?? [], forKey: .pendingInvites)
  }

  public func member(accountId: String) -> CommunityTableMember? {
    members.first { $0.accountId == accountId }
  }

  /// A table of 1 (owner alone) exists transiently after others leave (SPEC 5.1).
  public var isOwnerAlone: Bool { members.count <= 1 }
}

// MARK: - Invite (table-invite.schema.json)

/// Creator/owner view of an invite. `joinCode` is shown exactly once, to the creator, and
/// stored only as a hash server-side (SPEC 5.1); null in every response but createInvite.
public struct CommunityTableInvite: Codable, Sendable, Equatable, Hashable {
  public var inviteId: String
  public var requestedByDisplayName: String?
  public var state: CommunityInviteState
  public var expiresAt: String
  public var joinCode: String?

  public init(
    inviteId: String, requestedByDisplayName: String? = nil, state: CommunityInviteState,
    expiresAt: String, joinCode: String? = nil
  ) {
    self.inviteId = inviteId
    self.requestedByDisplayName = requestedByDisplayName
    self.state = state
    self.expiresAt = expiresAt
    self.joinCode = joinCode
  }

  enum CodingKeys: String, CodingKey {
    case inviteId, requestedByDisplayName, state, expiresAt, joinCode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inviteId = try container.decode(String.self, forKey: .inviteId)
    requestedByDisplayName = try container.decodeIfPresent(
      String.self, forKey: .requestedByDisplayName)
    state = try container.decode(CommunityInviteState.self, forKey: .state)
    expiresAt = try container.decode(String.self, forKey: .expiresAt)
    joinCode = try container.decodeIfPresent(String.self, forKey: .joinCode)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(inviteId, forKey: .inviteId)
    if let requestedByDisplayName {
      try container.encode(requestedByDisplayName, forKey: .requestedByDisplayName)
    } else {
      try container.encodeNil(forKey: .requestedByDisplayName)
    }
    try container.encode(state, forKey: .state)
    try container.encode(expiresAt, forKey: .expiresAt)
    if let joinCode {
      try container.encode(joinCode, forKey: .joinCode)
    } else {
      try container.encodeNil(forKey: .joinCode)
    }
  }
}

// MARK: - Join (table-join.schema.json)

public enum CommunityJoinState: String, Codable, Sendable, Hashable, CaseIterable {
  case pending, declined
}

/// The joiner's view after presenting a join code: the ask is `pending` until the owner
/// approves (202, SPEC 5.1). The table's name and id are the only things revealed before
/// approval.
public struct CommunityTableJoinView: Codable, Sendable, Equatable, Hashable {
  public var inviteId: String
  public var tableId: String
  public var tableName: String
  public var state: CommunityJoinState

  public init(inviteId: String, tableId: String, tableName: String, state: CommunityJoinState) {
    self.inviteId = inviteId
    self.tableId = tableId
    self.tableName = tableName
    self.state = state
  }

  enum CodingKeys: String, CodingKey {
    case inviteId, tableId, tableName, state
  }
}

/// Body of `POST /v1/tables` (CreateTableRequest).
public struct CommunityCreateTableRequest: Codable, Sendable, Equatable, Hashable {
  public var name: String

  public init(name: String) {
    self.name = name
  }

  enum CodingKeys: String, CodingKey {
    case name
  }
}

// MARK: - Shared cook (shared-cook.schema.json)

/// One swap on a shared cook ("curry powder" → "cumin + paprika").
public struct CommunityCookSwap: Codable, Sendable, Equatable, Hashable {
  public var fromName: String
  public var toName: String

  public init(fromName: String, toName: String) {
    self.fromName = fromName
    self.toName = toName
  }

  enum CodingKeys: String, CodingKey {
    case fromName, toName
  }
}

/// The overhaul SPEC 3.4 share payload, verbatim (community SPEC 5.2): revision reference,
/// dish name, servings, swaps, optional rating and one-line note, the day. Never pantry,
/// health, taste data, exact times or photos. `content` is carried only when the referenced
/// revision was never published — the one case where recipe content reaches the server
/// outside the publish flow (SPEC 5.2).
public struct CommunitySharedCook: Codable, Sendable, Equatable, Hashable {
  public var recipeRef: RecipeRef
  public var dishName: String
  public var servings: Int
  public var swaps: [CommunityCookSwap]
  public var rating: Int?
  public var note: String?
  /// The day only, never an exact time ("2026-10-14").
  public var day: String
  public var authorDisplayName: String?
  public var content: RecipeRevisionContent?

  public init(
    recipeRef: RecipeRef, dishName: String, servings: Int, swaps: [CommunityCookSwap] = [],
    rating: Int? = nil, note: String? = nil, day: String,
    authorDisplayName: String? = nil, content: RecipeRevisionContent? = nil
  ) {
    self.recipeRef = recipeRef
    self.dishName = dishName
    self.servings = servings
    self.swaps = swaps
    self.rating = rating
    self.note = note
    self.day = day
    self.authorDisplayName = authorDisplayName
    self.content = content
  }

  enum CodingKeys: String, CodingKey {
    case recipeRef, dishName, servings, swaps, rating, note, day, authorDisplayName, content
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    recipeRef = try container.decode(RecipeRef.self, forKey: .recipeRef)
    dishName = try container.decode(String.self, forKey: .dishName)
    servings = try container.decode(Int.self, forKey: .servings)
    swaps = try container.decode([CommunityCookSwap].self, forKey: .swaps)
    rating = try container.decodeIfPresent(Int.self, forKey: .rating)
    note = try container.decodeIfPresent(String.self, forKey: .note)
    day = try container.decode(String.self, forKey: .day)
    authorDisplayName = try container.decodeIfPresent(String.self, forKey: .authorDisplayName)
    content = try container.decodeIfPresent(RecipeRevisionContent.self, forKey: .content)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(recipeRef, forKey: .recipeRef)
    try container.encode(dishName, forKey: .dishName)
    try container.encode(servings, forKey: .servings)
    try container.encode(swaps, forKey: .swaps)
    if let rating {
      try container.encode(rating, forKey: .rating)
    } else {
      try container.encodeNil(forKey: .rating)
    }
    if let note {
      try container.encode(note, forKey: .note)
    } else {
      try container.encodeNil(forKey: .note)
    }
    try container.encode(day, forKey: .day)
    if let authorDisplayName {
      try container.encode(authorDisplayName, forKey: .authorDisplayName)
    } else {
      try container.encodeNil(forKey: .authorDisplayName)
    }
    if let content {
      try container.encode(content, forKey: .content)
    } else {
      try container.encodeNil(forKey: .content)
    }
  }
}

// MARK: - Table card (table-card.schema.json)

/// A shared cook as it appears in a Table feed (SPEC 5.2). `isMine` is set when the server
/// rendered the feed for this viewer; absent decodes as nil, encodes as null.
public struct CommunityTableCard: Codable, Sendable, Equatable, Hashable {
  public var cardId: String
  public var tableId: String
  public var cook: CommunitySharedCook
  public var isMine: Bool?
  public var createdAt: String

  public init(
    cardId: String, tableId: String, cook: CommunitySharedCook, isMine: Bool? = nil,
    createdAt: String
  ) {
    self.cardId = cardId
    self.tableId = tableId
    self.cook = cook
    self.isMine = isMine
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case cardId, tableId, cook, isMine, createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cardId = try container.decode(String.self, forKey: .cardId)
    tableId = try container.decode(String.self, forKey: .tableId)
    cook = try container.decode(CommunitySharedCook.self, forKey: .cook)
    isMine = try container.decodeIfPresent(Bool.self, forKey: .isMine)
    createdAt = try container.decode(String.self, forKey: .createdAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(cardId, forKey: .cardId)
    try container.encode(tableId, forKey: .tableId)
    try container.encode(cook, forKey: .cook)
    if let isMine {
      try container.encode(isMine, forKey: .isMine)
    } else {
      try container.encodeNil(forKey: .isMine)
    }
    try container.encode(createdAt, forKey: .createdAt)
  }

  /// A departed member's card stays in the table's history but renders without the cook
  /// content or their name (SPEC 5.1): the server drops `authorDisplayName`, collapses the
  /// payload, and sets the dish name to the mock's "Left the table" copy
  /// (`backend/community/src/modules/tables/views.ts:cardView`).
  public var isDepartedMemberRedaction: Bool {
    cook.authorDisplayName == nil && cook.dishName == "Left the table"
  }
}

/// Envelope of `GET /v1/tables/{tableId}/cards` — the #166-added read route the OpenAPI
/// document does not yet carry (named contract gap).
public struct CommunityTableCardList: Codable, Sendable, Equatable {
  public var cards: [CommunityTableCard]

  public init(cards: [CommunityTableCard]) {
    self.cards = cards
  }

  enum CodingKeys: String, CodingKey {
    case cards
  }
}

/// Body of `POST /v1/tables/{tableId}/cards` (ShareCookRequest). `operationId` is
/// client-generated (UUID) so the server deduplicates replays of the same outbox item
/// (SPEC 8.3).
public struct CommunityShareCookRequest: Codable, Sendable, Equatable, Hashable {
  public var operationId: String
  public var cook: CommunitySharedCook

  public init(operationId: String, cook: CommunitySharedCook) {
    self.operationId = operationId
    self.cook = cook
  }

  enum CodingKeys: String, CodingKey {
    case operationId, cook
  }
}

// MARK: - Blocks (block-list.schema.json)

/// One block row: private, mutual in effect, never announced to the blocked person
/// (SPEC 6.3).
public struct CommunityBlock: Codable, Sendable, Equatable, Hashable {
  public var accountId: String
  public var displayName: String?
  public var createdAt: String

  public init(accountId: String, displayName: String? = nil, createdAt: String) {
    self.accountId = accountId
    self.displayName = displayName
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case accountId, displayName, createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountId = try container.decode(String.self, forKey: .accountId)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    createdAt = try container.decode(String.self, forKey: .createdAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountId, forKey: .accountId)
    if let displayName {
      try container.encode(displayName, forKey: .displayName)
    } else {
      try container.encodeNil(forKey: .displayName)
    }
    try container.encode(createdAt, forKey: .createdAt)
  }
}

public struct CommunityBlockList: Codable, Sendable, Equatable {
  public var blocks: [CommunityBlock]

  public init(blocks: [CommunityBlock]) {
    self.blocks = blocks
  }

  enum CodingKeys: String, CodingKey {
    case blocks
  }
}

// MARK: - Reports (requests.schema.json#CreateReportRequest)

public enum CommunityReportTargetType: String, Codable, Sendable, Hashable, CaseIterable {
  case recipe
  case tableCard = "tableCard"
  case challengeEntry = "challengeEntry"
  case tableMember = "tableMember"
}

public enum CommunityReportReason: String, Codable, Sendable, Hashable, CaseIterable {
  case foodSafety = "food_safety"
  case rights
  case personalData = "personal_data"
  case spam
  case harassment
  case other
}

/// Body of `POST /v1/reports` (SPEC 6.4). The reported content hides from everyone pending
/// review; reports carry no counter and no reporter identity.
public struct CommunityCreateReportRequest: Codable, Sendable, Equatable, Hashable {
  public var targetType: CommunityReportTargetType
  public var targetId: String
  public var reason: CommunityReportReason
  public var detail: String?

  public init(
    targetType: CommunityReportTargetType, targetId: String, reason: CommunityReportReason,
    detail: String? = nil
  ) {
    self.targetType = targetType
    self.targetId = targetId
    self.reason = reason
    self.detail = detail
  }

  enum CodingKeys: String, CodingKey {
    case targetType, targetId, reason, detail
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    targetType = try container.decode(CommunityReportTargetType.self, forKey: .targetType)
    targetId = try container.decode(String.self, forKey: .targetId)
    reason = try container.decode(CommunityReportReason.self, forKey: .reason)
    detail = try container.decodeIfPresent(String.self, forKey: .detail)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(targetType, forKey: .targetType)
    try container.encode(targetId, forKey: .targetId)
    try container.encode(reason, forKey: .reason)
    if let detail {
      try container.encode(detail, forKey: .detail)
    } else {
      try container.encodeNil(forKey: .detail)
    }
  }
}
