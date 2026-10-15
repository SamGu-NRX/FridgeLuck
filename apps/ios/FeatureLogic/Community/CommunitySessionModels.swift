import Foundation

/// Session and identity wire types (`contracts/schemas/session.schema.json`,
/// `account.schema.json`, `error.schema.json`, and the `AuthAppleRequest` /
/// `AuthRefreshRequest` request bodies). Encoded shapes match the contract examples in
/// `contracts/examples/` byte-for-byte modulo key order (community SPEC 8.2).
///
/// Sign in with Apple itself (the button, the sheet, the `ASAuthorization` dance) is UI;
/// these types are what crosses the wire once the app holds an identity token.

// MARK: - Account (account.schema.json)

/// The signed-in user's own account view. Apple email and the Apple `sub` are never in any
/// other user's view; `displayName` is the only identity another user ever sees (SPEC 6.2).
public struct CommunityAccount: Codable, Sendable, Equatable, Hashable {
  public var accountId: String
  public var displayName: String
  /// True once the 18+ attestation is recorded (`attested18PlusAt`, first-write-wins).
  public var isAdult: Bool
  /// Null when the account may vote now; otherwise the UTC instant its votes start counting
  /// (account age ≥ 24 h, SPEC 4.3). The server, not the phone, enforces the gate.
  public var canVoteAt: String?
  /// True for allowlisted operator accounts; absent decodes as nil, encodes as null.
  public var moderationOperator: Bool?

  public init(
    accountId: String,
    displayName: String,
    isAdult: Bool,
    canVoteAt: String?,
    moderationOperator: Bool? = nil
  ) {
    self.accountId = accountId
    self.displayName = displayName
    self.isAdult = isAdult
    self.canVoteAt = canVoteAt
    self.moderationOperator = moderationOperator
  }

  enum CodingKeys: String, CodingKey {
    case accountId, displayName, isAdult, canVoteAt, moderationOperator
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountId = try container.decode(String.self, forKey: .accountId)
    displayName = try container.decode(String.self, forKey: .displayName)
    isAdult = try container.decode(Bool.self, forKey: .isAdult)
    canVoteAt = try container.decodeIfPresent(String.self, forKey: .canVoteAt)
    moderationOperator = try container.decodeIfPresent(Bool.self, forKey: .moderationOperator)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountId, forKey: .accountId)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(isAdult, forKey: .isAdult)
    if let canVoteAt {
      try container.encode(canVoteAt, forKey: .canVoteAt)
    } else {
      try container.encodeNil(forKey: .canVoteAt)
    }
    if let moderationOperator {
      try container.encode(moderationOperator, forKey: .moderationOperator)
    } else {
      try container.encodeNil(forKey: .moderationOperator)
    }
  }

  /// The instant votes start counting, or nil when the account may vote now.
  public var canVoteDate: Date? { canVoteAt.flatMap(CommunityContract.date(fromISO8601:)) }
}

// MARK: - Session (session.schema.json)

/// Server-issued session (PR #104 mechanics, SPEC 6.1): a short-lived `fla1.` access token
/// and a single-use `flr1.` refresh token. Tokens are opaque to the client.
public struct CommunitySession: Codable, Sendable, Equatable, Hashable {
  public var accessToken: String
  public var refreshToken: String
  public var account: CommunityAccount

  public init(accessToken: String, refreshToken: String, account: CommunityAccount) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.account = account
  }

  enum CodingKeys: String, CodingKey {
    case accessToken, refreshToken, account
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accessToken = try container.decode(String.self, forKey: .accessToken)
    refreshToken = try container.decode(String.self, forKey: .refreshToken)
    account = try container.decode(CommunityAccount.self, forKey: .account)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accessToken, forKey: .accessToken)
    try container.encode(refreshToken, forKey: .refreshToken)
    try container.encode(account, forKey: .account)
  }
}

// MARK: - Requests

/// The first-write-wins 18+ attestation carried on sign-in (SPEC 6.2); omitted when the
/// user is not signing in to share.
public struct CommunityBirthYearAttestation: Codable, Sendable, Equatable, Hashable {
  public var birthYear: Int

  public init(birthYear: Int) {
    self.birthYear = birthYear
  }

  enum CodingKeys: String, CodingKey {
    case birthYear
  }
}

/// Body of `POST /v1/auth/apple`. The Apple identity JWS is forwarded unmodified — the app
/// never sends decoded claims as proof (SPEC 6.1). `nonce` is the raw client-generated
/// nonce whose SHA-256 the app bound into the Apple sign-in request (SPEC 3.3): single-use
/// server-side, and the server compares the identity token's `nonce` claim against the
/// SHA-256 of this value, so a token minted outside the bound flow cannot replay.
public struct AuthAppleRequest: Codable, Sendable, Equatable, Hashable {
  public var identityToken: String
  public var nonce: String
  public var attest18Plus: CommunityBirthYearAttestation?

  public init(
    identityToken: String, nonce: String, attest18Plus: CommunityBirthYearAttestation? = nil
  ) {
    self.identityToken = identityToken
    self.nonce = nonce
    self.attest18Plus = attest18Plus
  }

  enum CodingKeys: String, CodingKey {
    case identityToken, nonce, attest18Plus
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identityToken = try container.decode(String.self, forKey: .identityToken)
    nonce = try container.decode(String.self, forKey: .nonce)
    attest18Plus = try container.decodeIfPresent(
      CommunityBirthYearAttestation.self, forKey: .attest18Plus)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(identityToken, forKey: .identityToken)
    try container.encode(nonce, forKey: .nonce)
    if let attest18Plus {
      try container.encode(attest18Plus, forKey: .attest18Plus)
    } else {
      try container.encodeNil(forKey: .attest18Plus)
    }
  }
}

/// Body of `POST /v1/auth/refresh`. The refresh token is single-use; its reuse revokes the
/// whole refresh family (SPEC 6.1).
public struct AuthRefreshRequest: Codable, Sendable, Equatable, Hashable {
  public var refreshToken: String

  public init(refreshToken: String) {
    self.refreshToken = refreshToken
  }

  enum CodingKeys: String, CodingKey {
    case refreshToken
  }
}

/// One-time sign-in nonce: a fresh lowercase UUID per attempt. The served contract requires
/// a UUID (`common.schema.json#/$defs/Uuid`) and the backend refuses reuse (first use wins)
/// and compares the value verbatim against the identity token's `nonce` claim
/// (`backend/community/src/core/appleVerify.ts:110`), so the `ASAuthorization` request must
/// bind this exact value. The SHA-256 hashing in the task's "hashed client nonce" is the
/// app↔Apple binding step (Apple's standard nonce flow), not a second client-side hash of
/// what crosses the wire.
public enum CommunityNonce {
  public static func generate() -> String {
    UUID().uuidString.lowercased()
  }

  /// The value the app binds into the `ASAuthorizationAppleIDRequest` (SPEC 3.3):
  /// SHA-256 of the raw nonce. The raw nonce itself never goes into the Apple
  /// request — Apple echoes the hash back inside the identity token's `nonce`
  /// claim, and the server compares that claim against the hash of the raw
  /// nonce the client sends in the sign-in body. A token minted without the
  /// bound hash is refused (the old verbatim-raw flow signs nothing in).
  public static func authorizationNonce(forRaw raw: String) -> String {
    SHA256.hexDigest(of: raw)
  }
}

/// Minimal SHA-256 (FIPS 180-4), vector-checked in the nonce tests. Foundation
/// on Linux has no CryptoKit and the community mirror compiles without
/// platform crypto dependencies (SPEC 8.5).
enum SHA256 {
  private static let k: [UInt32] = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

  static func hexDigest(of message: String) -> String {
    hexDigest(of: Array(message.utf8))
  }

  static func hexDigest(of bytes: [UInt8]) -> String {
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var message = bytes
    let bitLength = UInt64(bytes.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0x00) }
    for shift in stride(from: 56, through: 0, by: -8) {
      message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }
    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for chunkStart in stride(from: 0, to: message.count, by: 64) {
      var w = [UInt32](repeating: 0, count: 64)
      for i in 0..<16 {
        let o = chunkStart + i * 4
        w[i] = UInt32(message[o]) << 24 | UInt32(message[o + 1]) << 16 | UInt32(message[o + 2]) << 8 | UInt32(message[o + 3])
      }
      for i in 16..<64 {
        let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
        let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
      }
      var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
      for i in 0..<64 {
        let bigS1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        let ch = (e & f) ^ (~e & g)
        let temp1 = hh &+ bigS1 &+ ch &+ k[i] &+ w[i]
        let bigS0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        let maj = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = bigS0 &+ maj
        hh = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
      }
      h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
      h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
    return h.map { String(format: "%08x", $0) }.joined()
  }
}

// MARK: - Server error envelope (error.schema.json)

/// The decoded `{"error": {...}}` body the server returns on failures.
public struct CommunityErrorEnvelope: Codable, Sendable, Equatable {
  public var error: CommunityErrorBody

  public init(error: CommunityErrorBody) {
    self.error = error
  }

  enum CodingKeys: String, CodingKey {
    case error
  }
}

public struct CommunityErrorBody: Codable, Sendable, Equatable, Hashable {
  public var code: String
  public var message: String
  public var reason: String?

  public init(code: String, message: String, reason: String? = nil) {
    self.code = code
    self.message = message
    self.reason = reason
  }

  enum CodingKeys: String, CodingKey {
    case code, message, reason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(String.self, forKey: .code)
    message = try container.decode(String.self, forKey: .message)
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encode(message, forKey: .message)
    if let reason {
      try container.encode(reason, forKey: .reason)
    } else {
      try container.encodeNil(forKey: .reason)
    }
  }
}

/// Machine-readable server error codes the community surfaces name (community SPEC 4, 5, 6
/// and §9). Codes this client does not know decode as `.other`.
public enum CommunityServerErrorCode: Hashable, Sendable {
  /// 409 — a Table caps at 8 members (SPEC 5.1).
  case tableFull
  /// 409 — outside the entry window (SPEC 4.2).
  case entriesClosed
  /// 409 — voting not open yet (SPEC 4.2).
  case voteTooEarly
  /// 403 — account age under 24 h (#166 addition; SPEC 4.3).
  case accountTooNew
  /// 409 — the linked recipe revision moved on the server (SPEC 2.2).
  case recipeRevisedOffline
  /// 403 — the rights declaration no longer verifies (SPEC 2.3).
  case quarantinedRights
  /// 429 — rate limit.
  case rateLimited
  /// 403 — sharing requires the 18+ attestation (SPEC 6.2).
  case notAdult
  /// 422 — a free-text personal-data screen hit (SPEC 6.5).
  case personalData
  /// 403 — the blocked cannot vote on your entries (SPEC 6.3).
  case blocked
  case other(String)

  public init(code: String) {
    switch code {
    case "table_full": self = .tableFull
    case "entries_closed": self = .entriesClosed
    case "vote_too_early": self = .voteTooEarly
    case "account_too_new": self = .accountTooNew
    case "recipe_revised_offline": self = .recipeRevisedOffline
    case "quarantined_rights": self = .quarantinedRights
    case "rate_limited": self = .rateLimited
    case "not_adult": self = .notAdult
    case "personal_data": self = .personalData
    case "blocked": self = .blocked
    default: self = .other(code)
    }
  }

  public var rawCode: String {
    switch self {
    case .tableFull: return "table_full"
    case .entriesClosed: return "entries_closed"
    case .voteTooEarly: return "vote_too_early"
    case .accountTooNew: return "account_too_new"
    case .recipeRevisedOffline: return "recipe_revised_offline"
    case .quarantinedRights: return "quarantined_rights"
    case .rateLimited: return "rate_limited"
    case .notAdult: return "not_adult"
    case .personalData: return "personal_data"
    case .blocked: return "blocked"
    case .other(let code): return code
    }
  }
}
