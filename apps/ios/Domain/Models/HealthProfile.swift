import Foundation
import GRDB

// MARK: - Health Goal

enum HealthGoal: String, Sendable, Codable, CaseIterable, DatabaseValueConvertible {
  case general
  case weightLoss = "weight_loss"
  case muscleGain = "muscle_gain"
  case maintenance

  var displayName: String {
    switch self {
    case .general: "General Health"
    case .weightLoss: "Weight Loss"
    case .muscleGain: "Muscle Gain"
    case .maintenance: "Maintenance"
    }
  }

  var icon: String {
    switch self {
    case .general: "heart.circle"
    case .weightLoss: "arrow.down.circle"
    case .muscleGain: "dumbbell"
    case .maintenance: "scale.3d"
    }
  }

  var suggestedCalories: Int {
    switch self {
    case .general: 2000
    case .weightLoss: 1600
    case .muscleGain: 2500
    case .maintenance: 2200
    }
  }

  var defaultMacroSplit: (protein: Double, carbs: Double, fat: Double) {
    switch self {
    case .general: (0.25, 0.45, 0.30)
    case .weightLoss: (0.35, 0.35, 0.30)
    case .muscleGain: (0.35, 0.40, 0.25)
    case .maintenance: (0.30, 0.40, 0.30)
    }
  }
}

// MARK: - Health Profile

struct HealthProfile: Sendable, Codable {
  var id: Int64 = 1
  var displayName: String
  var age: Int?
  var goal: HealthGoal
  var dailyCalories: Int?
  var proteinPct: Double
  var carbsPct: Double
  var fatPct: Double
  var dietaryRestrictions: String  // JSON array string
  var allergenIngredientIds: String  // JSON array string
  var updatedAt: Date?

  static let `default` = HealthProfile(
    displayName: "",
    age: nil,
    goal: .general,
    dailyCalories: 2000,
    proteinPct: 0.25,
    carbsPct: 0.45,
    fatPct: 0.30,
    dietaryRestrictions: "[]",
    allergenIngredientIds: "[]"
  )

  var parsedDietaryRestrictions: [String] {
    guard let data = dietaryRestrictions.data(using: .utf8),
      let array = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return array
  }

  var normalizedDietaryRestrictionIDs: Set<String> {
    Set(
      parsedDietaryRestrictions.map {
        $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      })
  }

  var parsedAllergenIds: [Int64] {
    guard let data = allergenIngredientIds.data(using: .utf8),
      let array = try? JSONDecoder().decode([Int64].self, from: data)
    else {
      return []
    }
    return array
  }
}

extension HealthProfile {
  private static let supportedDietIDsInPriorityOrder: [String] = [
    "vegan",
    "vegetarian",
    "pescatarian",
    "keto",
  ]

  var normalizedDisplayName: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The single diet ID stored (e.g. "vegan", "keto"), or nil for "classic".
  var selectedDietID: String? {
    Self.canonicalDietID(from: normalizedDietaryRestrictionIDs)
  }

  var requiredRecipeTagMask: Int {
    var tags: RecipeTags = []
    let diet = selectedDietID

    switch diet {
    case "vegan": tags.insert(.vegan)
    case "vegetarian": tags.insert(.vegetarian)
    case "keto": tags.insert(.lowCarb)
    default: break
    }

    return tags.rawValue
  }

  var dietaryExcludedIngredientIds: Set<Int64> {
    var excluded: Set<Int64> = []
    let diet = selectedDietID

    if diet == "vegan" {
      excluded.formUnion([12, 13, 14, 32, 50])  // cheese, milk, butter, yogurt, sour cream
    }

    return excluded
  }

  var activeDietaryBadges: [String] {
    let labels: [(String, String)] = [
      ("pescatarian", "Pescatarian"),
      ("vegetarian", "Vegetarian"),
      ("vegan", "Vegan"),
      ("keto", "Keto"),
    ]

    let diet = selectedDietID
    return labels.compactMap { id, label in
      diet == id ? label : nil
    }
  }

  private static func canonicalDietID(from normalizedRestrictions: Set<String>) -> String? {
    for dietID in supportedDietIDsInPriorityOrder where normalizedRestrictions.contains(dietID) {
      return dietID
    }

    // Legacy profiles may still store low-carb as a restriction rather than the newer keto diet.
    if normalizedRestrictions.contains("low_carb") {
      return "keto"
    }

    return nil
  }
}

extension HealthProfile {
  enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case age
    case goal
    case dailyCalories = "daily_calories"
    case proteinPct = "protein_pct"
    case carbsPct = "carbs_pct"
    case fatPct = "fat_pct"
    case dietaryRestrictions = "dietary_restrictions"
    case allergenIngredientIds = "allergen_ingredient_ids"
    case updatedAt = "updated_at"
  }
}

extension HealthProfile: FetchableRecord, MutablePersistableRecord, TableRecord {
  static let databaseTableName = "health_profile"

  enum Columns: String, ColumnExpression {
    case id
    case displayName = "display_name"
    case age
    case goal
    case dailyCalories = "daily_calories"
    case proteinPct = "protein_pct"
    case carbsPct = "carbs_pct"
    case fatPct = "fat_pct"
    case dietaryRestrictions = "dietary_restrictions"
    case allergenIngredientIds = "allergen_ingredient_ids"
    case updatedAt = "updated_at"
  }

  func encode(to container: inout PersistenceContainer) {
    container[Columns.id] = id
    container[Columns.displayName] = displayName
    container[Columns.age] = age
    container[Columns.goal] = goal
    container[Columns.dailyCalories] = dailyCalories
    container[Columns.proteinPct] = proteinPct
    container[Columns.carbsPct] = carbsPct
    container[Columns.fatPct] = fatPct
    container[Columns.dietaryRestrictions] = dietaryRestrictions
    container[Columns.allergenIngredientIds] = allergenIngredientIds
    container[Columns.updatedAt] = updatedAt ?? Date()
  }
}
