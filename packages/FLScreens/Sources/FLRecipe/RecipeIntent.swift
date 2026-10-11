// FLRecipe — typed intents and the reducer.
//
// The reducer owns the observable document behaviour: the servings
// stepper (clamped), entering and advancing the step flow, the record
// flow opening when the last step completes, and the record fields.
// Sharing the record and related-chip navigation are host effects — the
// share preview is built host-side from the finished record and shows
// before anything is published (the same preview-first rule as Table).

import Foundation

/// Everything the Recipe screen can send.
public enum RecipeIntent: Equatable, Sendable {

    // Presentation logic (reducer-owned)

    /// The servings stepper. Clamped to 1...12 — the document rescales
    /// every line from the new factor.
    case setServings(Int)
    /// The primary action ("Cook for 2" / "Reheat for 1"): enter the step
    /// flow at step 1.
    case beginCook
    /// "Next" — advances; past the last step it opens the record flow.
    case nextStep
    /// "Skip" — behaves like Next for the flow, but the host's record
    /// distinguishes skipped steps when it logs the cook.
    case skipStep
    /// Leave the step flow without recording.
    case exitCook
    /// The record's rating (1...5, clamped).
    case setRating(Int)
    /// The record's "what did you do differently" line.
    case setDifferently(String)
    /// Close the record without saving.
    case dismissRecord

    // Navigation / effects (host-routed; reducer is identity)

    /// The record's save — host commits locally first (the cook record is
    /// the local write store's domain), share is a separate previewed act.
    case saveRecord
    /// The record's share entry — opens the host-built preview of exactly
    /// what would leave the phone.
    case shareRecord
    /// A related chip pushes another Recipe document.
    case openRelated(recipeID: String)
    /// Tap a photo to open it at full size with its source and rights.
    case openPhoto(photoID: String)
    /// Scan entry from the ingredient list (the search-role fallback).
    case scanKitchen
}

/// The stepper's bounds. The document scales down to one serving and up
/// to a small group; past 12 the per-line precision degrades into
/// guesses, which the honesty rules do not allow.
public enum RecipeBounds {
    public static let minServings = 1
    public static let maxServings = 12
    public static let minRating = 1
    public static let maxRating = 5
}

/// The reducer: pure, total over intents. `RecipeViewState.apply(_:)` is
/// the convenience views use.
public enum RecipeReducer {

    public static func reduced(_ state: RecipeViewState, by intent: RecipeIntent) -> RecipeViewState {
        var next = state
        switch intent {

        case .setServings(let servings):
            next.targetServings = min(
                max(servings, RecipeBounds.minServings), RecipeBounds.maxServings)

        case .beginCook:
            guard !next.steps.isEmpty else { break }
            next.currentStepIndex = 0
            next.showsRecord = false

        case .nextStep:
            guard let index = next.currentStepIndex else { break }
            if index + 1 < next.steps.count {
                next.currentStepIndex = index + 1
            } else {
                // Last step done: the step flow closes, the record opens,
                // and other cooks' notes disappear from the document.
                next.currentStepIndex = nil
                next.showsRecord = true
            }

        case .skipStep:
            next = reduced(next, by: .nextStep)

        case .exitCook:
            next.currentStepIndex = nil

        case .setRating(let rating):
            next.rating = min(max(rating, 1), RecipeBounds.maxRating)

        case .setDifferently(let text):
            next.didDifferently = text

        case .dismissRecord:
            next.showsRecord = false

        // Navigation and effects: the host owns the outcome.
        case .saveRecord, .shareRecord, .openRelated, .openPhoto, .scanKitchen:
            break
        }
        return next
    }
}

extension RecipeViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: RecipeIntent) {
        self = RecipeReducer.reduced(self, by: intent)
    }
}
