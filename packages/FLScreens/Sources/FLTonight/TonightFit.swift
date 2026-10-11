// FLTonight — the fit line, the app's central promise.
//
// SPEC 3.2: fit is stated from real line states. "9 of 10 · 1 swap" only
// when nine lines are sufficient and the shortfall is covered by real
// swaps; otherwise "7 recorded · check eggs and oil", naming the problem
// lines. Never a percentage; never "you have everything" unless every line
// is sufficient.
//
// The host's fit engine supplies the line states and the swap count; this
// type derives the display strings under those rules and nothing else.

/// The ingredient bill's fit, line by line, with the display rules the
/// pantry-truth contract requires.
public struct TonightFit: Equatable, Sendable {

    /// The state of one ingredient line — the five honest states of SPEC 3.2.
    public enum LineState: Equatable, Sendable {
        /// In the kitchen, quantity confirmed.
        case sufficient
        /// Short, with the amount that is missing.
        case short(amount: String)
        /// The scan could not tell how much there is.
        case quantityUnknown
        /// A staple the app assumes is present (always captioned "assumed").
        case assumedStaple
        /// Stale evidence; needs reconfirming.
        case needsReconfirming
    }

    /// One ingredient line.
    public struct Line: Equatable, Sendable {
        public var name: String
        public var state: LineState

        public init(name: String, state: LineState) {
            self.name = name
            self.state = state
        }
    }

    public var lines: [Line]

    /// Real swaps that would complete the dish, as computed by the host's
    /// fit engine. Never inferred here from line counts.
    public var swapsNeeded: Int

    /// Explanatory sentences for the shortfall, e.g.
    /// "Everything except lime." / "Swap in a lemon, you have two."
    public var notes: [String]

    public init(lines: [Line], swapsNeeded: Int = 0, notes: [String] = []) {
        self.lines = lines
        self.swapsNeeded = swapsNeeded
        self.notes = notes
    }

    // MARK: Derived values

    /// Lines whose state is sufficient.
    public var sufficientCount: Int {
        lines.filter { $0.state == .sufficient }.count
    }

    /// Total lines (sufficient and not).
    public var total: Int { lines.count }

    /// Lines that are not sufficient, in display order.
    public var shortfallLines: [Line] {
        lines.filter { $0.state != .sufficient }
    }

    /// True when every line is sufficient — the only condition under which
    /// the screen may say the kitchen covers the dish.
    public var allSufficient: Bool { shortfallLines.isEmpty }

    // MARK: Display strings (the honesty rules live here)

    /// The fit line itself.
    ///
    /// - Every line sufficient: "10 of 10".
    /// - Every shortfall a real swap covers: "9 of 10 · 1 swap".
    /// - Anything else: "7 recorded · check eggs and oil" — naming up to
    ///   two problem lines, then counting the rest.
    ///
    /// The grammar cannot produce a percentage or an unearned "you have
    /// everything": both properties are asserted by tests.
    public var lineText: String {
        let shortfalls = shortfallLines
        guard !shortfalls.isEmpty else { return "\(total) of \(total)" }

        let everyShortfallIsShort = shortfalls.allSatisfy { line in
            if case .short = line.state { return true } else { return false }
        }
        if everyShortfallIsShort, swapsNeeded > 0 {
            let swapWord = swapsNeeded == 1 ? "swap" : "swaps"
            return "\(sufficientCount) of \(total) · \(swapsNeeded) \(swapWord)"
        }

        let names = shortfalls.map(\.name)
        let head = names.prefix(2).joined(separator: " and ")
        let tail = names.count > 2 ? " and \(names.count - 2) more" : ""
        return "\(sufficientCount) recorded · check \(head)\(tail)"
    }
}
