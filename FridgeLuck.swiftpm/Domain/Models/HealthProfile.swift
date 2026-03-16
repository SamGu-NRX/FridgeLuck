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
  var normalizedDisplayName: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var requiredRecipeTagMask: Int {
    var tags: RecipeTags = []
    let restrictions = normalizedDietaryRestrictionIDs

    if restrictions.contains("vegan") {
      tags.insert(.vegan)
    } else if restrictions.contains("vegetarian") {
      tags.insert(.vegetarian)
    }

    if restrictions.contains("low_carb") {
      tags.insert(.lowCarb)
    }

    return tags.rawValue
  }

  var dietaryExcludedIngredientIds: Set<Int64> {
    let restrictions = normalizedDietaryRestrictionIDs
    var excluded: Set<Int64> = []

    if restrictions.contains("dairy_free") || restrictions.contains("vegan") {
      excluded.formUnion([12, 13, 14, 32, 50])  // cheese, milk, butter, yogurt, sour cream
    }

    if restrictions.contains("gluten_free") {
      excluded.formUnion([9, 15, 28, 31])  // pasta, bread, tortilla, oats
    }

    return excluded
  }

  var activeDietaryBadges: [String] {
    let labels: [(String, String)] = [
      ("vegetarian", "Vegetarian"),
      ("vegan", "Vegan"),
      ("gluten_free", "Gluten Free"),
      ("dairy_free", "Dairy Free"),
      ("low_carb", "Low Carb"),
    ]

    let restrictions = normalizedDietaryRestrictionIDs
    return labels.compactMap { id, label in
      restrictions.contains(id) ? label : nil
    }
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
