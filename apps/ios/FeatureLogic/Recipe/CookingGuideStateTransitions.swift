import Foundation

public enum CookingGuideStateTransitions {
  public static func toggleIngredient(_ ingredientID: Int64, checkedIngredients: inout Set<Int64>) {
    if checkedIngredients.contains(ingredientID) {
      checkedIngredients.remove(ingredientID)
    } else {
      checkedIngredients.insert(ingredientID)
    }
  }

  public static func toggleCompletedStep(_ stepIndex: Int, completedSteps: inout Set<Int>) {
    if completedSteps.contains(stepIndex) {
      completedSteps.remove(stepIndex)
    } else {
      completedSteps.insert(stepIndex)
    }
  }

  public static func substitutionSlot(for ingredientID: Int64?) -> Int64 {
    ingredientID ?? -1
  }
}
