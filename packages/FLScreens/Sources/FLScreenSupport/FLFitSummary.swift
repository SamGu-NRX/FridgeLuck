// FLScreenSupport — FLFitSummary, the row-grammar of the honest fit line.
//
// Part 3 screens (Explore rows, Table cards, the Recipe fit block) all
// state the same promise in the same voice. Tonight already owns a richer
// type (`TonightFit`, with per-line states) and stays untouched; this is
// the summary vocabulary those three screens share, with the same honesty
// rules SPEC 3.2 fixes for the hero:
//
// - "10 of 10" only when every line is sufficient.
// - "9 of 10 · 1 swap" only when the shortfall is real, swap-covered
//   shortfalls (the numeric form is never given away).
// - Otherwise the recorded form: "9 recorded · check eggs and oil",
//   naming at most two problem lines and counting the rest.
// - Never a percentage; never an unearned "you have everything".
//
// Foundation-only, Sendable, Equatable: Linux-tested in
// FLScreenSupportTests. Values are numbers and names the host's fit
// engine supplies; this type derives display strings and nothing else.

/// One row's, card's or recipe's fit, summarised for display.
public struct FLFitSummary: Equatable, Sendable {

    /// Lines that are sufficient.
    public var have: Int
    /// All lines, sufficient or not.
    public var total: Int
    /// Real swaps the host's fit engine found. Never inferred here.
    public var swapsNeeded: Int
    /// Names of the shortfall lines, for the recorded form. Empty when the
    /// host cannot name them.
    public var shortfallNames: [String]

    /// Clamps `have` into 0...total so a malformed engine answer can never
    /// render a count above the whole.
    public init(have: Int, total: Int, swapsNeeded: Int = 0, shortfallNames: [String] = []) {
        self.total = max(0, total)
        self.have = min(max(have, 0), self.total)
        self.swapsNeeded = max(0, swapsNeeded)
        self.shortfallNames = shortfallNames
    }

    /// True when every line is sufficient — the only condition under which
    /// anything may claim the kitchen covers the dish.
    public var isComplete: Bool { have >= total && total > 0 }

    /// The numeric form is earned only when every shortfall is a real,
    /// swap-covered one: at least one swap, and a name for every missing
    /// line so the record stays inspectable.
    private var shortfallIsSwapCovered: Bool {
        swapsNeeded > 0 && shortfallNames.count == total - have && have < total
    }

    /// The fit line itself: "10 of 10", "9 of 10 · 1 swap", or
    /// "9 recorded · check eggs and oil".
    public var lineText: String {
        guard !isComplete else { return "\(total) of \(total)" }

        if shortfallIsSwapCovered {
            let swapWord = swapsNeeded == 1 ? "swap" : "swaps"
            return "\(have) of \(total) · \(swapsNeeded) \(swapWord)"
        }

        let names = shortfallNames
        guard !names.isEmpty else { return "\(have) recorded" }
        let head = names.prefix(2).joined(separator: " and ")
        let tail = names.count > 2 ? " and \(names.count - 2) more" : ""
        return "\(have) recorded · check \(head)\(tail)"
    }

    /// The card caption's promise, stated in the Table mock's voice:
    /// "You have everything" ONLY when complete; otherwise what is
    /// missing, with the swap count when there is one
    /// ("Missing beansprouts · 1 swap").
    public var missingCaption: String {
        guard !isComplete else { return "You have everything" }
        let missing = total - have
        let swapClause: String = {
            guard swapsNeeded > 0 else { return "" }
            let swapWord = swapsNeeded == 1 ? "swap" : "swaps"
            return " · \(swapsNeeded) \(swapWord)"
        }()
        if shortfallIsSwapCovered {
            let head = shortfallNames.prefix(2).joined(separator: " and ")
            return "Missing \(head)\(swapClause)"
        }
        return "Missing \(missing)\(swapClause)"
    }
}
