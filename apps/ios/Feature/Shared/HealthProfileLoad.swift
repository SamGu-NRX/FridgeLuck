import Foundation

/// The health profile a screen edits, and whether it came from a successful read.
///
/// Settings and onboarding save the whole `health_profile` row. Editing
/// `HealthProfile.default` after a failed read and saving it wrote empty allergen and diet
/// lists over the household's stored ones, so a screen can only save a profile it actually
/// read. A fresh install has no row; `fetchHealthProfile` returns the default for it without
/// throwing, so that still counts as loaded.
enum HealthProfileLoad: Sendable {
  case loading
  case loaded(HealthProfile)
  case failed

  enum SaveError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
      "Your profile hasn't loaded, so nothing was saved. Try again."
    }
  }

  static func read(_ fetch: () throws -> HealthProfile) -> Self {
    do {
      return .loaded(try fetch())
    } catch {
      return .failed
    }
  }

  var profile: HealthProfile? {
    guard case .loaded(let profile) = self else { return nil }
    return profile
  }

  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }

  /// Applies `edit` to the loaded profile and writes it. Throws `SaveError.notLoaded`
  /// without writing anything unless the profile came from a successful read.
  @discardableResult
  func save(
    _ edit: (inout HealthProfile) throws -> Void,
    writing write: (HealthProfile) throws -> Void
  ) throws -> HealthProfile {
    guard var profile else { throw SaveError.notLoaded }
    try edit(&profile)
    try write(profile)
    return profile
  }
}
