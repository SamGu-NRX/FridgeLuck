// FLRecipe — typed intents and the reducer.
//
// The reducer owns the observable document behaviour: the servings
// stepper (clamped, and it INVALIDATES the fit pending the host's
// quantity-aware recomputation for the new target), entering and
// advancing the step flow, the per-step outcomes (completion and
// skipping are separate recorded states; the record opens only when the
// last step completes), the reviewed safety checks, and the record
// fields.
// Sharing the record and related-chip navigation are host effects — the
// share preview is built host-side from the finished record and shows
// before anything is published (the same preview-first rule as Table).

import Foundation
import FLScreenSupport

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
    /// "Skip" — advances like Next, but records the step as SKIPPED: its
    /// own recorded state, never folded into completion. Skipping the
    /// FINAL step closes the flow WITHOUT opening the record — a skipped
    /// final step must not produce a completed record.
    case skipStep
    /// Leave the step flow without recording.
    case exitCook
    /// The record's rating (1...5, clamped).
    case setRating(Int)
    /// The record's "what did you do differently" line.
    case setDifferently(String)
    /// The step's safety check was reviewed by the cook — e.g. the
    /// thermometer doneness read confirmed. Timers only say when to
    /// check; the REVIEWED check is what the record's completion needs.
    case safetyCheckReviewed(stepID: String, check: RecipeViewState.Step.SafetyCheck)
    /// The host's quantity-aware fit recomputation returned. Applied only
    /// when it names the CURRENT target — a result for an earlier
    /// serving count is stale and dropped, never shown.
    case fitRecomputed(fit: FLFitSummary, forServings: Int)
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
            let clamped = min(
                max(servings, RecipeBounds.minServings), RecipeBounds.maxServings)
            next.targetServings = clamped
            // The shown fit was computed for the PREVIOUS target — a
            // doubled bill cannot keep the old sufficiency claims, and
            // `ingredient.isInKitchen` presence says nothing about the
            // new amounts. The fit stays pending (no sufficiency claim,
            // no Cook-enabled assertion) until the host's quantity-aware
            // result for THIS target arrives via .fitRecomputed.
            if clamped != state.targetServings {
                next.fitValidity = .pendingRecompute(forServings: clamped)
            }

        case .beginCook:
            guard !next.steps.isEmpty else { break }
            next.currentStepIndex = 0
            next.showsRecord = false
            // A fresh cook session: no outcomes recorded, no checks
            // reviewed.
            next.stepOutcomes = Array(repeating: nil, count: next.steps.count)
            next.reviewedChecks = [:]

        case .nextStep:
            guard let index = next.currentStepIndex, index < next.steps.count else { break }
            // Gone through — recorded as completed, its own state.
            next.stepOutcomes[index] = .completed
            if index + 1 < next.steps.count {
                next.currentStepIndex = index + 1
            } else {
                // Last step COMPLETED: the step flow closes, the record
                // opens, and other cooks' notes disappear from the
                // document. The record's completion is constructed from
                // these outcomes (and the reviewed checks) — a host
                // callback alone cannot assert it.
                next.currentStepIndex = nil
                next.showsRecord = true
            }

        case .skipStep:
            guard let index = next.currentStepIndex, index < next.steps.count else { break }
            // Skipping is its own recorded state — never folded into
            // completion.
            next.stepOutcomes[index] = .skipped
            if index + 1 < next.steps.count {
                next.currentStepIndex = index + 1
            } else {
                // The FINAL step was skipped: nothing completed here.
                // The flow closes WITHOUT the record — a skipped final
                // step must not produce a completed record.
                next.currentStepIndex = nil
                next.showsRecord = false
            }

        case .safetyCheckReviewed(let stepID, let check):
            // Reducer-owned bookkeeping: the reviewed check is recorded
            // against the step, and the record's completion requires it
            // (doneness needs a reviewed thermometer check; timers only
            // say when to check).
            next.reviewedChecks[stepID, default: []].insert(check)

        case .fitRecomputed(let fit, let forServings):
            // Apply the host's quantity-aware result only for the
            // CURRENT target — a stale result for an earlier serving
            // count is dropped, never shown.
            guard forServings == next.targetServings else { break }
            next.fit = fit
            next.fitValidity = .current

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
