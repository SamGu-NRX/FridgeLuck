// FLScreenSupport — FLFitSummary, the row-grammar of the honest fit line.
//
// Part 3 screens (Explore rows, Table cards, the Recipe fit block) all
// state the same promise in the same voice. Tonight already owns a richer
// type (`TonightFit`, with per-line states) and stays untouched; this is
// the summary vocabulary those three screens share, with the same honesty
// rules SPEC 3.2 fixes for the hero:
//
// - "10 of 10" only when every line is sufficient.
// - "9 of 10 · 1 swap" only when the shortfall is real and coverage of
//   every shortfall is VALIDATED — the host accepted a swap for each
//   named line (the numeric form is never given away by a bare count).
// - Partially validated coverage states what is known: "1 swap accepted,
//   2 items still to check".
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
    /// Shortfall lines whose swap the host has ACCEPTED — validated
    /// coverage, carried by name. A bare `swapsNeeded` count only says the
    /// fit engine found real swaps; it names no line, so it proves no
    /// line is covered. Only a name here that matches a `shortfallNames`
    /// entry validates that line's coverage.
    public var swapCoveredNames: [String]

    /// Clamps `have` into 0...total so a malformed engine answer can never
    /// render a count above the whole.
    public init(
        have: Int, total: Int, swapsNeeded: Int = 0, shortfallNames: [String] = [],
        swapCoveredNames: [String] = []
    ) {
        self.total = max(0, total)
        self.have = min(max(have, 0), self.total)
        self.swapsNeeded = max(0, swapsNeeded)
        self.shortfallNames = shortfallNames
        self.swapCoveredNames = swapCoveredNames
    }

    /// True when every line is sufficient — the only condition under which
    /// anything may claim the kitchen covers the dish.
    public var isComplete: Bool { have >= total && total > 0 }

    /// The shortfall names this summary validates as covered: entries of
    /// `swapCoveredNames` that name an actual shortfall. A swap accepted
    /// for a line that is not a shortfall covers nothing.
    public var validatedCoveredNames: [String] {
        shortfallNames.filter { swapCoveredNames.contains($0) }
    }

    /// The shortfall names with no accepted swap — the lines still to
    /// check.
    public var unvalidatedShortfallNames: [String] {
        shortfallNames.filter { !swapCoveredNames.contains($0) }
    }

    /// True when coverage of EVERY shortfall is validated by an accepted
    /// swap (and the shortfall is real and fully named, so the record
    /// stays inspectable). Only this earns the numeric
    /// complete-after-swaps form — and a "Cook with swap" promise. A bare
    /// positive swap count never does.
    public var isCompleteAfterSwaps: Bool {
        have < total
            && swapsNeeded > 0
            && !shortfallNames.isEmpty
            && shortfallNames.count == total - have
            && validatedCoveredNames.count == shortfallNames.count
    }

    /// The fit line itself: "10 of 10", "9 of 10 · 1 swap",
    /// "1 swap accepted, 2 items still to check", or
    /// "9 recorded · check eggs and oil".
    public var lineText: String {
        guard !isComplete else { return "\(total) of \(total)" }

        // The numeric complete-after-swaps form is earned only by
        // validated coverage of every shortfall — never by a bare count.
        if isCompleteAfterSwaps {
            let swapWord = swapsNeeded == 1 ? "swap" : "swaps"
            return "\(have) of \(total) · \(swapsNeeded) \(swapWord)"
        }

        // Coverage is not fully validated: state what is actually known —
        // the accepted swaps, and how many lines are still to check.
        let uncovered = unvalidatedShortfallNames
        let accepted = validatedCoveredNames.count
        if accepted > 0, !uncovered.isEmpty {
            let swapWord = accepted == 1 ? "swap" : "swaps"
            let itemWord = uncovered.count == 1 ? "item" : "items"
            return "\(accepted) \(swapWord) accepted, \(uncovered.count) \(itemWord) still to check"
        }

        guard !uncovered.isEmpty else { return "\(have) recorded" }
        let head = uncovered.prefix(2).joined(separator: " and ")
        let tail = uncovered.count > 2 ? " and \(uncovered.count - 2) more" : ""
        return "\(have) recorded · check \(head)\(tail)"
    }

    /// The card caption's promise, stated in the Table mock's voice:
    /// "You have everything" ONLY when complete; otherwise what is
    /// missing — with the swap count only when coverage of every
    /// shortfall is validated ("Missing eggs · 1 swap"), the accepted
    /// count when coverage is partial ("Missing eggs and oil · 1 swap
    /// accepted"), and no swap clause when nothing is validated (a found
    /// count that covers no named line is not a claim).
    public var missingCaption: String {
        guard !isComplete else { return "You have everything" }
        let missing = total - have
        let swapClause: String = {
            if isCompleteAfterSwaps {
                let swapWord = swapsNeeded == 1 ? "swap" : "swaps"
                return " · \(swapsNeeded) \(swapWord)"
            }
            let accepted = validatedCoveredNames.count
            guard accepted > 0 else { return "" }
            let swapWord = accepted == 1 ? "swap" : "swaps"
            return " · \(accepted) \(swapWord) accepted"
        }()
        if isCompleteAfterSwaps {
            let head = shortfallNames.prefix(2).joined(separator: " and ")
            return "Missing \(head)\(swapClause)"
        }
        let uncovered = unvalidatedShortfallNames
        if uncovered.isEmpty {
            return "Missing \(missing)\(swapClause)"
        }
        let head = uncovered.prefix(2).joined(separator: " and ")
        let tail = uncovered.count > 2 ? " and \(uncovered.count - 2) more" : ""
        return "Missing \(head)\(tail)\(swapClause)"
    }
}
