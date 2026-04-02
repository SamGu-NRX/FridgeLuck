import Foundation
import GRDB

enum NotificationRuleKind: String, Sendable, Codable, CaseIterable, DatabaseValueConvertible,
  Identifiable
{
  case mealBreakfast = "meal_breakfast"
  case mealLunch = "meal_lunch"
  case mealSnack = "meal_snack"
  case mealDinner = "meal_dinner"
  case mealEndOfDay = "meal_end_of_day"
  case useSoonAlerts = "use_soon_alerts"

  static let orderedMealKinds: [NotificationRuleKind] = [
    .mealBreakfast,
    .mealLunch,
    .mealSnack,
    .mealDinner,
    .mealEndOfDay,
  ]

  var title: String {
    switch self {
    case .mealBreakfast: return "Breakfast"
    case .mealLunch: return "Lunch"
    case .mealSnack: return "Snack"
    case .mealDinner: return "Dinner"
    case .mealEndOfDay: return "End of Day"
    case .useSoonAlerts: return "Use-soon alerts"
    }
  }

  var detail: String {
    switch self {
    case .mealBreakfast:
      return "A quick nudge to log breakfast."
    case .mealLunch:
      return "A quick nudge to log lunch."
    case .mealSnack:
      return "A quick nudge to log snacks."
    case .mealDinner:
      return "A quick nudge to log dinner."
    case .mealEndOfDay:
      return "Catch anything you ate before the day closes."
    case .useSoonAlerts:
      return "Get a daily nudge when food is close to expiring."
    }
  }

  var defaultEnabled: Bool {
    switch self {
    case .mealBreakfast, .mealLunch, .mealDinner, .useSoonAlerts:
      return true
    case .mealSnack, .mealEndOfDay:
      return false
    }
  }

  var defaultHour: Int {
    switch self {
    case .mealBreakfast: return 8
    case .mealLunch: return 11
    case .mealSnack: return 16
    case .mealDinner: return 18
    case .mealEndOfDay: return 21
    case .useSoonAlerts: return 18
    }
  }

  var defaultMinute: Int {
    switch self {
    case .mealBreakfast: return 30
    case .mealLunch: return 30
    case .mealSnack: return 0
    case .mealDinner: return 0
    case .mealEndOfDay: return 0
    case .useSoonAlerts: return 0
    }
  }

  var isMealReminder: Bool {
    self != .useSoonAlerts
  }

  var notificationIdentifier: String {
    switch self {
    case .mealBreakfast: return "tracking.meal.breakfast"
    case .mealLunch: return "tracking.meal.lunch"
    case .mealSnack: return "tracking.meal.snack"
    case .mealDinner: return "tracking.meal.dinner"
    case .mealEndOfDay: return "tracking.meal.end_of_day"
    case .useSoonAlerts: return "tracking.kitchen.use_soon"
    }
  }

  var notificationTitle: String {
    switch self {
    case .mealBreakfast: return "Log breakfast"
    case .mealLunch: return "Log lunch"
    case .mealSnack: return "Log your snack"
    case .mealDinner: return "Log dinner"
    case .mealEndOfDay: return "Wrap up today"
    case .useSoonAlerts: return "Use-soon alert"
    }
  }

  var notificationBody: String {
    switch self {
    case .mealBreakfast:
      return "Keep your day accurate while breakfast is still fresh in mind."
    case .mealLunch:
      return "Log lunch while it still takes two taps."
    case .mealSnack:
      return "A quick snack log keeps your day honest."
    case .mealDinner:
      return "Log dinner before the night gets away from you."
    case .mealEndOfDay:
      return "Check off anything you ate today before the day closes."
    case .useSoonAlerts:
      return "You have ingredients that should be used soon."
    }
  }

  var id: String { rawValue }
}

struct NotificationRule: Identifiable, Sendable, Codable {
  var id: Int64?
  var kind: NotificationRuleKind
  var enabled: Bool
  var hour: Int
  var minute: Int
  var updatedAt: Date?

  static func makeDefault(kind: NotificationRuleKind) -> NotificationRule {
    NotificationRule(
      id: nil,
      kind: kind,
      enabled: kind.defaultEnabled,
      hour: kind.defaultHour,
      minute: kind.defaultMinute,
      updatedAt: nil
    )
  }

  var scheduledDateComponents: DateComponents {
    DateComponents(hour: hour, minute: minute)
  }
}

extension NotificationRule {
  enum CodingKeys: String, CodingKey {
    case id
    case kind
    case enabled
    case hour
    case minute
    case updatedAt = "updated_at"
  }
}

extension NotificationRule: FetchableRecord, MutablePersistableRecord, TableRecord {
  static let databaseTableName = "notification_rules"

  enum Columns: String, ColumnExpression {
    case id
    case kind
    case enabled
    case hour
    case minute
    case updatedAt = "updated_at"
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  func encode(to container: inout PersistenceContainer) {
    container[Columns.id] = id
    container[Columns.kind] = kind
    container[Columns.enabled] = enabled
    container[Columns.hour] = hour
    container[Columns.minute] = minute
    container[Columns.updatedAt] = updatedAt ?? Date()
  }
}

enum NotificationOpportunityKind: String, Sendable, Codable, DatabaseValueConvertible {
  case useSoonDigest = "use_soon_digest"
}

enum NotificationOpportunitySource: String, Sendable, Codable, DatabaseValueConvertible {
  case backend
  case local
}

enum NotificationOpportunityStatus: String, Sendable, Codable, DatabaseValueConvertible {
  case scheduled
  case obsolete
}

struct NotificationOpportunity: Identifiable, Sendable, Codable {
  var id: String
  var kind: NotificationOpportunityKind
  var title: String
  var body: String
  var scheduledAt: Date
  var payloadJSON: String
  var source: NotificationOpportunitySource
  var status: NotificationOpportunityStatus
  var updatedAt: Date?
}

extension NotificationOpportunity {
  enum CodingKeys: String, CodingKey {
    case id
    case kind
    case title
    case body
    case scheduledAt = "scheduled_at"
    case payloadJSON = "payload_json"
    case source
    case status
    case updatedAt = "updated_at"
  }
}

extension NotificationOpportunity: FetchableRecord, MutablePersistableRecord, TableRecord {
  static let databaseTableName = "notification_opportunities"

  enum Columns: String, ColumnExpression {
    case id
    case kind
    case title
    case body
    case scheduledAt = "scheduled_at"
    case payloadJSON = "payload_json"
    case source
    case status
    case updatedAt = "updated_at"
  }

  func encode(to container: inout PersistenceContainer) {
    container[Columns.id] = id
    container[Columns.kind] = kind
    container[Columns.title] = title
    container[Columns.body] = body
    container[Columns.scheduledAt] = scheduledAt
    container[Columns.payloadJSON] = payloadJSON
    container[Columns.source] = source
    container[Columns.status] = status
    container[Columns.updatedAt] = updatedAt ?? Date()
  }
}

struct NotificationSyncRule: Sendable, Codable {
  let kind: NotificationRuleKind
  let enabled: Bool
  let hour: Int
  let minute: Int
  let pushToken: String?
}

struct NotificationSyncInventoryItem: Sendable, Codable {
  let ingredientId: Int64
  let ingredientName: String
  let quantityGrams: Double
  let expiresAt: Date?
  let confidenceScore: Double
}

struct NotificationSyncRequest: Sendable, Codable {
  let installationId: String
  let timezone: String
  let locale: String
  let generatedAt: Date
  let rules: [NotificationSyncRule]
  let inventorySnapshot: [NotificationSyncInventoryItem]
}

struct NotificationSyncOpportunityPayload: Sendable, Codable {
  let ingredientIds: [Int64]
  let ingredientNames: [String]
  let expiresAt: [Date]
}

struct NotificationSyncResponseOpportunity: Sendable, Codable {
  let id: String
  let kind: NotificationOpportunityKind
  let title: String
  let body: String
  let scheduledAt: Date
  let payload: NotificationSyncOpportunityPayload
}

struct NotificationSyncResponse: Sendable, Codable {
  let generatedAt: Date
  let opportunities: [NotificationSyncResponseOpportunity]
}
