import Foundation

/// Storage seam for the session's access and refresh tokens: Keychain in the app
/// (`KeychainCommunityTokenStore`), in-memory in tests (community SPEC 8.5).
public protocol CommunityTokenStore: Sendable {
  func read() async throws -> CommunitySessionTokens?
  func write(_ tokens: CommunitySessionTokens) async throws
  func clear() async throws
}

/// The token pair behind the protocol: the `fla1.` access token and the single-use `flr1.`
/// refresh token, stored together so rotation is atomic (SPEC 6.1).
public struct CommunitySessionTokens: Codable, Sendable, Equatable, Hashable {
  public var accessToken: String
  public var refreshToken: String

  public init(accessToken: String, refreshToken: String) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
  }

  enum CodingKeys: String, CodingKey {
    case accessToken, refreshToken
  }
}

/// Test double: tokens live only for the process lifetime.
public final class InMemoryCommunityTokenStore: CommunityTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: CommunitySessionTokens?

  public init() {}

  public func read() async throws -> CommunitySessionTokens? {
    locked { tokens }
  }

  public func write(_ tokens: CommunitySessionTokens) async throws {
    locked { self.tokens = tokens }
  }

  public func clear() async throws {
    locked { tokens = nil }
  }

  /// NSLock.lock() is unavailable from asynchronous contexts (Swift 6 / macOS CI
  /// run 38820110049): the lock is taken and released inside this synchronous
  /// nonisolated method, so the async entry points never call it lexically.
  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
