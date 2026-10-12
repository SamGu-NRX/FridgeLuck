// FLRecipe — the Recipe screen's view state.
//
// The document view (Direction H's Recipe mock): hero, mono stats, the
// ingredient list scaled to YOUR servings, numbered steps with photos,
// the community tips, related chips, and the cook record's preview.
// Binding rules this state encodes:
//
// - "Cook for 2" scales every line to the viewer's servings; the base
//   recipe's numbers are never shown instead (the stepper is at the top
//   because it changes the whole document). Quantities are derived here,
//   deterministically and testably.
// - Same-document record (from a Tonight record): the primary action is
//   "Reheat for 1" and the record's context is shown — this screen serves
//   both the fresh recipe and the "what did I actually do" document.
// - Steps carry their count ("Step 2 of 5") and one Next/Skip control;
//   step notes from other cooks show while you cook and disappear after
//   the cook is recorded — your record is yours, not a re-read of theirs.
// - Tips are community notes ("38% added lemon"), never owner-curated
//   marketing; there is no field for an owner reply.
// - The fit line is the same honest grammar as everywhere else
//   (`FLFitSummary`): "10 of 10 · 3 swaps" counts only real swaps.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLRecipeTests.

import FLScreenSupport

/// The whole Recipe screen as a value.
public struct RecipeViewState: Equatable, Sendable {

    /// One ingredient line, scaled to the viewer's servings on demand.
    public struct Ingredient: Equatable, Sendable, Identifiable {

        public var id: String
        /// "butter", "eggs" — the line name.
        public var name: String
        /// The BASE quantity (at `baseServings`). Nil for count-less lines
        /// like "a handful of basil" — scaling must not invent precision.
        public var baseQuantity: Double?
        /// "g", "tbsp" — nil when the quantity counts the name itself
        /// ("2 eggs" has unit nil and name "eggs").
        public var unit: String?
        /// The viewer has this line (the tick in the mock).
        public var isInKitchen: Bool
        /// An accepted substitution, when the fit engine found one:
        /// "use kale instead".
        public var swapDisplay: String?

        public init(
            id: String, name: String, baseQuantity: Double? = nil, unit: String? = nil,
            isInKitchen: Bool = false, swapDisplay: String? = nil
        ) {
            self.id = id
            self.name = name
            self.baseQuantity = baseQuantity
            self.unit = unit
            self.isInKitchen = isInKitchen
            self.swapDisplay = swapDisplay
        }
    }

    /// One numbered step.
    public struct Step: Equatable, Sendable, Identifiable {

        /// A safety check a step can require, as explicit state. The
        /// canon binds the RECORD, not just the recipe text: doneness
        /// requires a reviewed thermometer check, and timers only say
        /// when to check — the review is what the record needs.
        public enum SafetyCheck: Equatable, Sendable {
            /// The step's doneness must be confirmed with a reviewed
            /// thermometer read.
            case thermometerDoneness
            /// The step requires a timed rest before results are judged.
            case timedRest
        }

        public var id: String
        /// "Make the dressing", "Colour the ginger".
        public var title: String
        public var body: String
        /// The working caption of the step's photo, when it has one.
        public var photoCaption: String?
        /// An other-cook note attached to this step, shown only while
        /// cooking ("Add the ginger late or it burns.").
        public var cookNote: String?
        /// The safety checks this step requires — explicit state, never
        /// left implicit in the text. A completed cook can only be
        /// asserted when every required check was reviewed.
        public var requiredChecks: [SafetyCheck]

        public init(
            id: String, title: String, body: String, photoCaption: String? = nil,
            cookNote: String? = nil, requiredChecks: [SafetyCheck] = []
        ) {
            self.id = id
            self.title = title
            self.body = body
            self.photoCaption = photoCaption
            self.cookNote = cookNote
            self.requiredChecks = requiredChecks
        }
    }

    /// A related-recipe chip ("Sun-dress the eggs", "Spring soup").
    public struct Related: Equatable, Sendable, Identifiable {

        public var id: String
        public var title: String
        /// "8 of 10 · 1 swap" — the chip carries the same honest fit.
        public var fitLine: String

        public init(id: String, title: String, fitLine: String) {
            self.id = id
            self.title = title
            self.fitLine = fitLine
        }
    }

    // MARK: State

    public var recipeID: String
    public var title: String
    /// "Maya" — the mock's byline sits under the title.
    public var publisherDisplay: String
    /// "v3 · tested 12 times" — the version line, host-supplied verbatim.
    public var revisionDisplay: String
    /// Total minutes, host-supplied; display derives ("35 min").
    public var minutes: Int
    /// The viewer's own fit for this recipe.
    public var fit: FLFitSummary
    /// The hero photo's working caption, when there is a photo.
    public var heroCaption: String?
    /// The recipe's authored servings — what its quantities are written for.
    public var baseServings: Int
    /// The viewer's target — the stepper's value. Scaling re-derives from
    /// this everywhere.
    public var targetServings: Int
    public var ingredients: [Ingredient]
    public var steps: [Step]
    /// Index into `steps` while cooking; nil when browsing (no step UI).
    public var currentStepIndex: Int?
    /// The record flow is open (last step done). Rating and the
    /// what-you-did-differently line live here.
    public var showsRecord: Bool
    /// "4 of 5" as 4 — nil until the cook rates.
    public var rating: Int?
    /// "used less salt" — the record's one-line difference.
    public var didDifferently: String
    /// Community tips ("38% added lemon. You and Maya both do.").
    public var tips: [String]
    public var related: [Related]
    /// This document IS a tonight record: the primary action is "Reheat
    /// for 1", and the record's context is visible.
    public var isTonightRecord: Bool

    /// The fit's standing for the CURRENT target. A servings change
    /// invalidates the shown fit — it was computed for the previous
    /// target — and stays pending until the host's quantity-aware
    /// recomputation for THAT target returns. While pending, the fit
    /// makes no sufficiency claim and the primary action asserts no
    /// kitchen coverage.
    public enum FitValidity: Equatable, Sendable {
        /// The fit describes the current target.
        case current
        /// Stale: computed for a different target; pending the host's
        /// recomputation for `forServings`.
        case pendingRecompute(forServings: Int)
    }

    /// What happened at each step this session, parallel to `steps`
    /// (nil = not reached yet). Completion and skipping are separate
    /// recorded states; the record is constructed from these outcomes —
    /// never asserted by a host callback.
    public enum StepOutcome: Equatable, Sendable {
        /// The cook went through the step.
        case completed
        /// The cook skipped the step — recorded as its own state.
        case skipped
    }

    public var fitValidity: FitValidity
    public var stepOutcomes: [StepOutcome?]
    /// Safety checks reviewed this session, by step id. The record's
    /// completion requires every required check to appear here.
    public var reviewedChecks: [String: Set<Step.SafetyCheck>]

    public init(
        recipeID: String, title: String, publisherDisplay: String,
        revisionDisplay: String, minutes: Int, fit: FLFitSummary,
        heroCaption: String? = nil, baseServings: Int = 2, targetServings: Int = 2,
        ingredients: [Ingredient] = [], steps: [Step] = [], currentStepIndex: Int? = nil,
        showsRecord: Bool = false, rating: Int? = nil, didDifferently: String = "",
        tips: [String] = [], related: [Related] = [], isTonightRecord: Bool = false,
        fitValidity: FitValidity = .current,
        stepOutcomes: [StepOutcome?]? = nil,
        reviewedChecks: [String: Set<Step.SafetyCheck>] = [:]
    ) {
        self.recipeID = recipeID
        self.title = title
        self.publisherDisplay = publisherDisplay
        self.revisionDisplay = revisionDisplay
        self.minutes = minutes
        self.fit = fit
        self.heroCaption = heroCaption
        self.baseServings = max(1, baseServings)
        self.targetServings = max(1, targetServings)
        self.ingredients = ingredients
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.showsRecord = showsRecord
        self.rating = rating
        self.didDifferently = didDifferently
        self.tips = tips
        self.related = related
        self.isTonightRecord = isTonightRecord
        self.fitValidity = fitValidity
        // Outcomes always parallel the steps: sized and nil unless a
        // matching session was supplied.
        if let stepOutcomes, stepOutcomes.count == steps.count {
            self.stepOutcomes = stepOutcomes
        } else {
            self.stepOutcomes = Array(repeating: nil, count: steps.count)
        }
        self.reviewedChecks = reviewedChecks
    }

    // MARK: Derived — servings and scaling

    /// The scaling factor. Guarded against a zero base (init clamps it to
    /// at least 1, so this cannot divide by zero).
    public var scaleFactor: Double {
        Double(targetServings) / Double(baseServings)
    }

    /// A quantity formatted for a line: integers plain ("130"), one
    /// decimal otherwise ("1.5") — never "130.0 g" or "1.4999999 tbsp".
    static func quantityDisplay(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    /// The scaled quantity alone ("130 g"), for row components that carry
    /// the name separately (FLQuantityRow). Empty for count-less lines.
    public func scaledQuantityDisplay(for ingredient: Ingredient) -> String {
        guard let base = ingredient.baseQuantity else { return "" }
        let scaled = base * scaleFactor
        let number = Self.quantityDisplay(scaled)
        return ingredient.unit.map { "\(number) \($0)" } ?? number
    }

    /// The scaled line for one ingredient: "260 g butter" from a 130 g
    /// base at ×2, or "a handful of basil" untouched when the line has no
    /// number.
    public func scaledDisplay(for ingredient: Ingredient) -> String {
        guard ingredient.baseQuantity != nil else { return ingredient.name }
        let quantity = scaledQuantityDisplay(for: ingredient)
        return "\(quantity) \(ingredient.name)"
    }

    /// "Cook for 2" — or "Reheat for 1" on a tonight record.
    public var primaryActionTitle: String {
        let verb = isTonightRecord ? "Reheat" : "Cook"
        return "\(verb) for \(targetServings)"
    }

    /// "35 min".
    public var minutesDisplay: String { "\(minutes) min" }

    /// The mono stats line under the title: "10 of 10 · 3 swaps · 35 min".
    /// While the fit is pending (servings changed, the host's
    /// recomputation out) it states the check instead of stale claims:
    /// "checking your kitchen for 4 · 35 min".
    public var statsDisplay: String {
        let fitPart = fitIsPending
            ? "checking your kitchen for \(targetServings)"
            : fit.lineText
        return [fitPart, minutesDisplay].joined(separator: " · ")
    }

    /// True while the shown fit was computed for a different target: the
    /// stepper changed servings and the host's quantity-aware
    /// recomputation has not returned. The pending fit makes no
    /// sufficiency claim.
    public var fitIsPending: Bool {
        if case .pendingRecompute = fitValidity { return true }
        return false
    }

    /// The primary action may start the cook flow regardless — cooking is
    /// always allowed — but while the fit is pending the state asserts no
    /// kitchen coverage behind it, and views must not present it as
    /// fit-backed until the host's result for the current target returns.
    public var primaryActionIsFitBacked: Bool { !fitIsPending }

    // MARK: Derived — step flow

    /// "Step 2 of 5", nil while browsing.
    public var stepCountDisplay: String? {
        guard let index = currentStepIndex, !steps.isEmpty else { return nil }
        return "Step \(index + 1) of \(steps.count)"
    }

    /// Other cooks' notes show while cooking, never after the record.
    public var showsStepNotes: Bool { currentStepIndex != nil }

    /// The steps of the current cook, in order (the mock's numbered stack).
    public var isCooking: Bool { currentStepIndex != nil }

    /// The cook record's completion, CONSTRUCTED from the recorded step
    /// outcomes and the reviewed checks. The screen's completed state
    /// matches the saved record because both derive from these outcomes
    /// here — a host callback alone cannot produce the assertion.
    public enum RecordCompletion: Equatable, Sendable {
        /// Every step completed (none skipped) and every required safety
        /// check reviewed — the only state a completed cook may be
        /// asserted from.
        case completed
        /// The flow ended without full completion: skipped steps and/or
        /// unreviewed required checks, counted.
        case incomplete(skippedSteps: Int, unreviewedChecks: Int)
    }

    /// Nil until the flow has reached every step (each carries an
    /// outcome).
    public var recordCompletion: RecordCompletion? {
        guard !steps.isEmpty, stepOutcomes.count == steps.count,
              !stepOutcomes.contains(where: { $0 == nil })
        else { return nil }
        let skipped = stepOutcomes.filter { $0 == .skipped }.count
        let unreviewed = steps.reduce(0) { count, step in
            let reviewed = reviewedChecks[step.id] ?? []
            return count + step.requiredChecks.filter { !reviewed.contains($0) }.count
        }
        if skipped == 0 && unreviewed == 0 { return .completed }
        return .incomplete(skippedSteps: skipped, unreviewedChecks: unreviewed)
    }

    /// The completed-cook assertion: true only when the record flow is
    /// open AND the constructed completion is `.completed`. A skipped
    /// final step, or a required check that never ran, never yields it.
    public var completedCookIsAssertable: Bool {
        showsRecord && recordCompletion == .completed
    }
}
