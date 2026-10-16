import Foundation

/// The allergen re-check performed when a substitution is applied (LeChef §7). Persisted as
/// canonical JSON beside every swap row — the record shows what was checked and whether the
/// swap was blocked, including the unknown-composition case, which blocks (fail closed).
public struct CookSubstitutionRecheck: Equatable, Sendable {
  /// Whether the substitute is (or may be) an allergen for any eater.
  public let blocked: Bool
  /// The eater allergen ids that were checked against, as strings.
  public let checkedIDs: [String]

  public init(blocked: Bool, checkedIDs: [String]) {
    self.blocked = blocked
    self.checkedIDs = checkedIDs
  }

  /// Deterministic key order and no whitespace — the receipt stores this string (LeChef §8).
  public var canonicalJSON: String {
    let ids = checkedIDs
      .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
      .sorted()
      .joined(separator: ",")
    return "{\"blocked\":\(blocked),\"checked\":[\(ids)]}"
  }
}
