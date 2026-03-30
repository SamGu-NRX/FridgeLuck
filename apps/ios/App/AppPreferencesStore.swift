import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - Enums

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

enum AppMeasurementUnit: String, CaseIterable, Identifiable, Sendable {
  case metric
  case imperial

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .metric: "Metric"
    case .imperial: "Imperial"
    }
  }
}

// MARK: - Preferences Store

@MainActor
@Observable
final class AppPreferencesStore {
  private enum Keys {
    static let appearance = "appPref_appearance"
    static let measurementUnit = "appPref_measurementUnit"
    static let defaultServings = "appPref_defaultServings"
    static let hapticsEnabled = "appPref_hapticsEnabled"
  }

  private static var hapticDefaults: UserDefaults = .standard

  private let defaults: UserDefaults

  var appearance: AppAppearance {
    didSet {
      defaults.set(appearance.rawValue, forKey: Keys.appearance)
    }
  }

  var measurementUnit: AppMeasurementUnit {
    didSet {
      defaults.set(measurementUnit.rawValue, forKey: Keys.measurementUnit)
    }
  }

  var defaultServings: Int {
    didSet {
      defaults.set(defaultServings, forKey: Keys.defaultServings)
    }
  }

  var hapticsEnabled: Bool {
    didSet {
      defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    Self.hapticDefaults = defaults

    if let raw = defaults.string(forKey: Keys.appearance),
      let value = AppAppearance(rawValue: raw)
    {
      self.appearance = value
    } else {
      self.appearance = .system
    }

    if let raw = defaults.string(forKey: Keys.measurementUnit),
      let value = AppMeasurementUnit(rawValue: raw)
    {
      self.measurementUnit = value
    } else {
      self.measurementUnit = .metric
    }

    if defaults.object(forKey: Keys.defaultServings) != nil {
      self.defaultServings = defaults.integer(forKey: Keys.defaultServings)
    } else {
      self.defaultServings = 1
    }

    if defaults.object(forKey: Keys.hapticsEnabled) != nil {
      self.hapticsEnabled = defaults.bool(forKey: Keys.hapticsEnabled)
    } else {
      self.hapticsEnabled = true
    }
  }

  func formatWeight(grams: Double) -> String {
    switch measurementUnit {
    case .metric:
      return "\(Int(grams.rounded()))g"
    case .imperial:
      let oz = grams / 28.3495
      if oz >= 16 {
        let lbs = oz / 16
        return String(format: "%.1f lb", lbs)
      }
      return String(format: "%.1f oz", oz)
    }
  }

  func reset() {
    appearance = .system
    measurementUnit = .metric
    defaultServings = 1
    hapticsEnabled = true
  }

  // MARK: - Static haptic helpers (no environment needed)

  #if canImport(UIKit)
    static var isHapticsEnabled: Bool {
      let defaults = hapticDefaults
      if defaults.object(forKey: Keys.hapticsEnabled) != nil {
        return defaults.bool(forKey: Keys.hapticsEnabled)
      }
      return true
    }

    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
      guard isHapticsEnabled else { return }
      UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
      guard isHapticsEnabled else { return }
      UINotificationFeedbackGenerator().notificationOccurred(type)
    }
  #endif
}
