import Foundation

/// What the user chose during onboarding, written over the profile onboarding loaded.
///
/// Onboarding seeds its steps from the stored profile. When that read failed, the steps
/// showed defaults, and finishing setup wrote empty diet and allergen lists over an existing
/// household. Completion now goes through `HealthProfileLoad.save`, which refuses unless the
/// read succeeded.
struct OnboardingProfileChoices: Sendable {
  let displayName: String
  let age: Int
  let goal: HealthGoal
  let dailyCalories: Int
  /// "classic" stores no diet.
  let dietID: String
  let allergenIDs: Set<Int64>

  func complete(
    over load: HealthProfileLoad,
    writing write: (HealthProfile) throws -> Void
  ) throws {
    let diets = dietID == "classic" ? [String]() : [dietID]
    let restrictions = try Self.encodeJSON(diets)
    let allergens = try Self.encodeJSON(allergenIDs.sorted())
    let split = goal.defaultMacroSplit

    try load.save({ profile in
      profile.displayName = displayName
      profile.age = age
      profile.goal = goal
      profile.dailyCalories = dailyCalories
      profile.proteinPct = split.protein
      profile.carbsPct = split.carbs
      profile.fatPct = split.fat
      profile.dietaryRestrictions = restrictions
      profile.allergenIngredientIds = allergens
    }, writing: write)
  }

  private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
      throw CocoaError(.coderInvalidValue)
    }
    return json
  }
}
