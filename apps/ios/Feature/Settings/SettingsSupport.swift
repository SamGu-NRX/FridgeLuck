import FLFeatureLogic
import Foundation
import SwiftUI

enum SettingsDietOption: String, CaseIterable, Identifiable {
  case classic
  case vegan
  case vegetarian
  case pescatarian
  case keto

  var id: String { rawValue }

  var title: String {
    switch self {
    case .classic: return "Classic"
    case .vegan: return "Vegan"
    case .vegetarian: return "Vegetarian"
    case .pescatarian: return "Pescatarian"
    case .keto: return "Keto"
    }
  }

  var icon: String {
    switch self {
    case .classic: return "fork.knife"
    case .vegan: return "leaf.fill"
    case .vegetarian: return "carrot"
    case .pescatarian: return "fish"
    case .keto: return "flame.fill"
    }
  }

  var shortDescription: String {
    switch self {
    case .classic: return "No restrictions, all recipes"
    case .vegan: return "No animal products"
    case .vegetarian: return "No meat or fish"
    case .pescatarian: return "Fish but no meat"
    case .keto: return "High fat, low carb"
    }
  }

  init(profile: HealthProfile) {
    switch profile.selectedDietID {
    case "vegan": self = .vegan
    case "vegetarian": self = .vegetarian
    case "pescatarian": self = .pescatarian
    case "keto": self = .keto
    default: self = .classic
    }
  }

  var storedRestrictions: [String] {
    switch self {
    case .classic: return []
    default: return [rawValue]
    }
  }
}

extension AppPermissionStatus {
  var settingsLabel: String {
    switch self {
    case .authorized: return "Allowed"
    case .limited: return "Limited"
    case .notDetermined: return "Not set"
    case .denied: return "Denied"
    case .restricted: return "Restricted"
    case .unavailable: return "Unavailable"
    }
  }

  var settingsDetail: String {
    switch self {
    case .authorized:
      return "FridgeLuck can use this feature when needed."
    case .limited:
      return "FridgeLuck has partial access."
    case .notDetermined:
      return "You have not decided yet."
    case .denied:
      return "Access is off and requires a trip to iOS Settings."
    case .restricted:
      return "Access is restricted by device or parental settings."
    case .unavailable:
      return "This feature is not available on this device."
    }
  }

  var settingsBadge: FLSettingsBadge {
    switch self {
    case .authorized:
      return FLSettingsBadge(text: settingsLabel, tone: .positive)
    case .limited:
      return FLSettingsBadge(text: settingsLabel, tone: .accent)
    case .notDetermined:
      return FLSettingsBadge(text: settingsLabel, tone: .neutral)
    case .denied, .restricted:
      return FLSettingsBadge(text: settingsLabel, tone: .warning)
    case .unavailable:
      return FLSettingsBadge(text: settingsLabel, tone: .neutral)
    }
  }

  var isAllowedForSettings: Bool {
    self == .authorized || self == .limited
  }

  var statusColor: Color {
    switch self {
    case .authorized: return AppTheme.sage
    case .limited: return AppTheme.oat
    case .notDetermined: return AppTheme.textSecondary
    case .denied: return AppTheme.accent
    case .restricted: return AppTheme.accent
    case .unavailable: return AppTheme.textSecondary
    }
  }
}
