import Foundation
import Observation

@MainActor
@Observable
final class FirstRunExperienceStore {
  static let currentVersion = 1

  private enum Keys {
    static let completedVersion = "firstRunExperienceCompletedVersion"
    static let appleHealthChoice = "firstRunExperienceAppleHealthChoice"
  }

  enum AppleHealthChoice: String, Sendable {
    case unresolved
    case skipped
    case connected
  }

  private let defaults: UserDefaults

  var completedVersion: Int {
    didSet {
      defaults.set(completedVersion, forKey: Keys.completedVersion)
    }
  }

  var appleHealthChoice: AppleHealthChoice {
    didSet {
      defaults.set(appleHealthChoice.rawValue, forKey: Keys.appleHealthChoice)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.completedVersion = defaults.integer(forKey: Keys.completedVersion)

    if let rawValue = defaults.string(forKey: Keys.appleHealthChoice),
      let choice = AppleHealthChoice(rawValue: rawValue)
    {
      self.appleHealthChoice = choice
    } else {
      self.appleHealthChoice = .unresolved
    }
  }

  var hasCompletedCurrentVersion: Bool {
    completedVersion >= Self.currentVersion
  }

  func markCompletedCurrentVersion() {
    completedVersion = Self.currentVersion
  }

  func markLegacyCompletionIfNeeded() {
    guard !hasCompletedCurrentVersion else { return }
    markCompletedCurrentVersion()
  }

  func reset() {
    completedVersion = 0
    appleHealthChoice = .unresolved
  }
}
