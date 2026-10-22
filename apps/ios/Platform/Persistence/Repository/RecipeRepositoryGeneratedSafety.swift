import FLFeatureLogic
import Foundation
import GRDB

extension RecipeRepository {
  func generatedRecipeVerdict(profile: HealthProfile) throws -> HouseholdSafetyVerdict {
    // The profile's parsed helpers turn invalid JSON into empty arrays. Generation must
    // refuse a corrupt profile instead of treating it as an unrestricted household.
    _ = try JSONDecoder().decode([Int64].self, from: Data(profile.allergenIngredientIds.utf8))
    let restrictions = try JSONDecoder().decode(
      [String].self, from: Data(profile.dietaryRestrictions.utf8))
    if !restrictions.isEmpty && profile.selectedDietID == nil {
      return .blocked(.unknownComposition)
    }
    return try db.read { db in
      try HouseholdSafetyBoundary.load(profile: profile, in: db).unstructuredRecipeVerdict()
    }
  }
}
