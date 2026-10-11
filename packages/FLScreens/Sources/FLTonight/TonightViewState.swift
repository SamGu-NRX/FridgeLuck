// FLTonight — Tonight's view state.
//
// "Tonight is a default, not a verdict" (SPEC 2). The state carries every
// explicit state the screen can be in — unknown kitchen, the pick, sparse
// kitchen, nothing feasible — as plain values. The host (FridgeLuckCore at
// integration) computes fit and ranking; this layer owns only what the
// SCREEN must get right: honest fit lines, the rejection constraint
// pattern, and the guarantee that "Choose tomorrow" is never taken away.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLTonightTests.

/// The whole screen as a value. SwiftUI views render exactly this; typed
/// intents (`TonightIntent`) flow back through the host's send closure and
/// the reducer (`TonightReducer`) applies the presentation-logic ones.
public struct TonightViewState: Equatable, Sendable {

    /// What the large title says. "Late" is a host decision (after 21:30 the
    /// pick becomes tomorrow's dinner) — no clock lives in this layer, so
    /// the rule stays testable and the cutoff can change without a rebuild.
    public enum Heading: String, Sendable {
        case tonight
        case tomorrow
    }

    /// Why the kitchen is unknown. Manual entry is first-class in all three;
    /// the reason only shapes the hero's wording.
    public enum UnknownKitchenReason: String, Equatable, Sendable {
        case neverScanned
        case cameraRefused
        case recognitionFailed
    }

    /// The pick's meal metadata, displayed as one mono line
    /// ("25 min · 2 servings · 520 kcal").
    public struct MealMeta: Equatable, Sendable {
        public var minutes: Int
        public var servings: Int
        /// Nil when the recipe carries no nutrition snapshot — the line
        /// omits kcal rather than inventing it.
        public var kilocalories: Int?

        public init(minutes: Int, servings: Int, kilocalories: Int? = nil) {
            self.minutes = minutes
            self.servings = servings
            self.kilocalories = kilocalories
        }

        /// "25 min · 2 servings · 520 kcal" — numerals are mono at render
        /// time; this is the plain string.
        public var display: String {
            var parts = ["\(minutes) min", "\(servings) servings"]
            if let kilocalories { parts.append("\(kilocalories) kcal") }
            return parts.joined(separator: " · ")
        }
    }

    /// A photo the pick may carry. The layout obeys `PhotoLayoutRule`
    /// (3:2, capped at 40% of screen height); the caption is the working
    /// placeholder text until a real photo exists.
    public struct PhotoSpec: Equatable, Sendable {
        public var caption: String
        /// False while only the placeholder exists.
        public var isLoaded: Bool

        public init(caption: String, isLoaded: Bool = false) {
            self.caption = caption
            self.isLoaded = isLoaded
        }
    }

    /// The evidence line under the fit: counts, never flattery. Tapping it
    /// opens the taste-profile sentence it came from.
    public struct WhyLine: Equatable, Sendable {
        public var text: String
        /// The profile sentence this evidence came from, when there is one.
        public var profileSentenceID: String?

        public init(text: String, profileSentenceID: String? = nil) {
            self.text = text
            self.profileSentenceID = profileSentenceID
        }
    }

    /// The one honest pick: dish, meta, photo, fit and why.
    public struct Pick: Equatable, Sendable {
        public var recipeID: String
        public var title: String
        public var meta: MealMeta
        public var photo: PhotoSpec?
        public var fit: TonightFit
        public var why: WhyLine?

        public init(
            recipeID: String, title: String, meta: MealMeta, photo: PhotoSpec? = nil,
            fit: TonightFit, why: WhyLine? = nil
        ) {
            self.recipeID = recipeID
            self.title = title
            self.meta = meta
            self.photo = photo
            self.fit = fit
            self.why = why
        }
    }

    /// The hero's substance — the four explicit states of SPEC 2.
    public enum Content: Equatable, Sendable {
        /// No scan yet, camera refused, or recognition failed. A sample
        /// pick may be shown below the hero, labelled "Example"; manual
        /// entry stays first-class.
        case unknownKitchen(reason: UnknownKitchenReason, example: Pick?)

        /// The normal state: one honest pick.
        case pick(Pick)

        /// Sparse kitchen (3–5 items known): the pick stays and the fit
        /// line becomes the honest "You'd need" list — never a fake
        /// "cook with 2 swaps".
        case sparse(pick: Pick, youdNeed: [String])

        /// Nothing feasible: the closest pick still shows, the primary
        /// button states its real swap count, and the escapes are the
        /// shopping list and saved recipes — never an invented pick.
        case nothingFeasible(pick: Pick)
    }

    /// A "Use soon" row: name, optional quantity, and the timing word the
    /// chip carries ("2 days", "tomorrow", "today").
    public struct UseSoonItem: Equatable, Sendable {
        public var id: String
        public var name: String
        public var quantityDisplay: String?
        public var timing: String

        public init(id: String, name: String, quantityDisplay: String? = nil, timing: String) {
            self.id = id
            self.name = name
            self.quantityDisplay = quantityDisplay
            self.timing = timing
        }
    }

    /// An "Also possible" row.
    public struct Alternative: Equatable, Sendable {
        public var recipeID: String
        public var title: String
        public var reason: String
        public var minutesDisplay: String
        public var fitHave: Int
        public var fitTotal: Int

        public init(
            recipeID: String, title: String, reason: String, minutesDisplay: String,
            fitHave: Int, fitTotal: Int
        ) {
            self.recipeID = recipeID
            self.title = title
            self.reason = reason
            self.minutesDisplay = minutesDisplay
            self.fitHave = fitHave
            self.fitTotal = fitTotal
        }
    }

    /// A cook in progress replaces the hero with a resume bar.
    public struct CookResume: Equatable, Sendable {
        public var dish: String
        public var stepSummary: String
        /// Display label for the running timer, when one runs.
        public var timerLabel: String?
        public var timerRunning: Bool

        public init(dish: String, stepSummary: String, timerLabel: String? = nil, timerRunning: Bool = false) {
            self.dish = dish
            self.stepSummary = stepSummary
            self.timerLabel = timerLabel
            self.timerRunning = timerRunning
        }
    }

    /// A taste pattern the profile wants to ask about, once: "You've taken
    /// coriander out 5 times. Stop suggesting it? Yes / No". Asked once,
    /// never repeated; either answer dismisses it here. The answer's
    /// effect on ranking is the host's business — this layer records no
    /// taste data anywhere (rejections never become dislikes).
    public struct TasteQuestion: Equatable, Sendable {
        public var id: String
        public var text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    // MARK: State

    public var heading: Heading
    /// "Sat 11 Oct" — set by the host, never computed here (no clock).
    public var dateLabel: String
    public var content: Content
    /// Non-nil replaces the hero with the resume bar; everything else
    /// (use soon, alternatives) stays.
    public var activeCook: CookResume?
    public var useSoon: [UseSoonItem]
    public var alternatives: [Alternative]
    public var tasteQuestion: TasteQuestion?
    /// Why and table lines arrive late: their height is reserved and one
    /// 2 pt indeterminate line shows (no shimmer). Local fit is instant.
    public var lateLinesLoading: Bool
    /// Recommendation service down: the last pick carries this stamp in the
    /// eyebrow ("As of 6:10 pm"). Fit, use soon and alternatives compute on
    /// device and always render.
    public var pickAsOf: String?
    /// First session only: the scan action gets an accent ring.
    public var isFirstSession: Bool
    /// Meal context summary ("For you and Ana"), computed upstream from the
    /// eaters. Restrictions never live here — the union is the host's job.
    public var contextSummary: String?
    /// After the third "Something else": offer the constraint choice.
    public var constraintsOffered: Bool
    /// How many "Something else" presses this session has logged. The count
    /// itself is presentation bookkeeping — it never feeds taste.
    public var rejectionCount: Int

    public init(
        heading: Heading = .tonight,
        dateLabel: String,
        content: Content,
        activeCook: CookResume? = nil,
        useSoon: [UseSoonItem] = [],
        alternatives: [Alternative] = [],
        tasteQuestion: TasteQuestion? = nil,
        lateLinesLoading: Bool = false,
        pickAsOf: String? = nil,
        isFirstSession: Bool = false,
        contextSummary: String? = nil,
        constraintsOffered: Bool = false,
        rejectionCount: Int = 0
    ) {
        self.heading = heading
        self.dateLabel = dateLabel
        self.content = content
        self.activeCook = activeCook
        self.useSoon = useSoon
        self.alternatives = alternatives
        self.tasteQuestion = tasteQuestion
        self.lateLinesLoading = lateLinesLoading
        self.pickAsOf = pickAsOf
        self.isFirstSession = isFirstSession
        self.contextSummary = contextSummary
        self.constraintsOffered = constraintsOffered
        self.rejectionCount = rejectionCount
    }

    // MARK: Contracts the screen must not be able to break

    /// "The user can choose tomorrow; there is no clock cutoff" (SPEC 2).
    /// The view binds its Choose-tomorrow control's visibility to this, so
    /// a state can never quietly remove the option.
    public var canChooseTomorrow: Bool { true }

    /// The pick the content carries, when any — used by the views for the
    /// photo block and by tests for the reducer's serving edits.
    public var carriedPick: Pick? {
        switch content {
        case .unknownKitchen(_, let example): return example
        case .pick(let pick): return pick
        case .sparse(let pick, _): return pick
        case .nothingFeasible(let pick): return pick
        }
    }

    /// True when the primary action should state its real swap count
    /// (the nothing-feasible state).
    public var primaryActionStatesSwaps: Bool {
        if case .nothingFeasible = content { return true }
        return false
    }
}
