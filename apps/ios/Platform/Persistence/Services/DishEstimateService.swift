import Foundation
import GRDB

enum DishPortionSize: String, CaseIterable, Sendable {
  case small
  case normal
  case large

  var displayName: String {
    switch self {
    case .small: return "Small"
    case .normal: return "Normal"
    case .large: return "Large"
    }
  }

  var multiplier: Double {
    switch self {
    case .small: return 0.8
    case .normal: return 1.0
    case .large: return 1.25
    }
  }
}

struct NutrientRange: Sendable {
  let min: Double
  let max: Double
}

struct PreparedDishEstimate: Sendable {
  let calories: NutrientRange
  let protein: NutrientRange
  let carbs: NutrientRange
  let fat: NutrientRange
}

/// Estimates prepared dish nutrition ranges from template priors + portion size.
final class DishEstimateService: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  func templates() throws -> [DishTemplate] {
    try db.read { db in
      try DishTemplate.order(DishTemplate.Columns.name.asc).fetchAll(db)
    }
  }

  func estimate(template: DishTemplate, size: DishPortionSize) -> PreparedDishEstimate {
    // Range spread keeps expectations realistic for cooked dishes.
    let lower = size.multiplier * 0.85
    let upper = size.multiplier * 1.15

    func range(_ value: Double) -> NutrientRange {
      NutrientRange(min: value * lower, max: value * upper)
    }

    return PreparedDishEstimate(
      calories: range(template.baseCalories),
      protein: range(template.baseProtein),
      carbs: range(template.baseCarbs),
      fat: range(template.baseFat)
    )
  }
}
