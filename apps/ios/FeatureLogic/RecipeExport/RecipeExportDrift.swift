import Foundation

/// Drift compares only identity-bearing fields: the recipe's name and base
/// servings, the row count, and each row's name, requiredness, substitute, and
/// note. Amount or unit edits after preparation are not drift — the prepared
/// document already carries its own values, and re-preparing is not forced for
/// cosmetic changes.
enum RecipeExportDriftEvaluation {
  static func isStale(liveIntake: RecipeExportIntake, prepared: RecipeExportPrepared) -> Bool {
    let captured = prepared.capturedInputs
    if liveIntake.recipeName != captured.recipeName { return true }
    if liveIntake.originalServings != captured.originalServings { return true }
    if liveIntake.rows.count != captured.rows.count { return true }
    for (live, capturedRow) in zip(liveIntake.rows, captured.rows) {
      if live.name != capturedRow.name { return true }
      if live.isRequired != capturedRow.isRequired { return true }
      if live.substitutedName != capturedRow.substitutedName { return true }
      if live.replacementNote != capturedRow.replacementNote { return true }
    }
    return false
  }
}
