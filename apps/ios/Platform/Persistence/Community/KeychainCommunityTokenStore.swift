import FLFeatureLogic
import Foundation
import Security

/// Keychain-backed `CommunityTokenStore` (community SPEC 8.5): one generic-password item
/// holding the JSON-encoded session tokens. Deleting the item signs the account out.
/// Not part of the Linux `community-check` mirror — Security is Apple-only.
public struct KeychainCommunityTokenStore: CommunityTokenStore {
  private let service: String
  private let account: String

  public init(service: String, account: String = "community-session") {
    self.service = service
    self.account = account
  }

  public func read() async throws -> CommunitySessionTokens? {
    var query = baseQuery
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else {
      if status == errSecItemNotFound { return nil }
      throw CommunityKeychainError.status(status)
    }
    guard let data = item as? Data else { return nil }
    return try JSONDecoder().decode(CommunitySessionTokens.self, from: data)
  }

  public func write(_ tokens: CommunitySessionTokens) async throws {
    let data = try JSONEncoder().encode(tokens)
    let update: [String: Any] = [kSecValueData as String: data]

    var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = baseQuery
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw CommunityKeychainError.status(status)
    }
  }

  public func clear() async throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CommunityKeychainError.status(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

public enum CommunityKeychainError: Error, Equatable {
  case status(OSStatus)
}
