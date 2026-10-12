// FLTonight — the fit line, the app's central promise.
//
// SPEC 3.2: fit is stated from real line states. "9 of 10 · 1 swap" only
// when nine lines are sufficient and the shortfall is covered by real
// swaps; otherwise "7 recorded · check eggs and oil", naming the problem
// lines. Never a percentage; never "you have everything" unless every line
// is sufficient.
//
// The host's fit engine supplies the line states and the validated swap
// coverage; this type derives the display strings under those rules and
// nothing else. Two shortages plus one unrelated swap is not coverage:
// the count grammar is earned by a validated complete-after-swaps
// result, never by an unbound integer.

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

        /// True for the plain `.short` state — the only shortfall a
        /// swap grammar may cover.
        var isShort: Bool {
            if case .short = self { return true }
            return false
        }
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

    /// A swap the host's fit engine validated against one specific
    /// shortfall: `coversLine` names the short line the swap covers. A
    /// swap that names no shortfall — or coverage that misses one —
    /// buys no claim anywhere in this type.
    public struct SwapCoverage: Equatable, Sendable {
        /// The short line this swap covers (matches `Line.name`).
        public var coversLine: String

        public init(coversLine: String) {
            self.coversLine = coversLine
        }
    }

    public var lines: [Line]

    /// Real swaps validated per shortfall by the host's fit engine, each
    /// naming the one short line it covers. Never inferred here from
    /// line counts, and never an unbound integer.
    public var swaps: [SwapCoverage]

    /// Explanatory sentences for the shortfall, e.g.
    /// "Everything except lime." / "Swap in a lemon, you have two."
    public var notes: [String]

    public init(lines: [Line], swaps: [SwapCoverage] = [], notes: [String] = []) {
        self.lines = lines
        self.swaps = swaps
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

    /// The validated complete-after-swaps result: the count of real
    /// swaps, but only when every shortfall line is a plain short line
    /// and every one of those lines is covered by the validated swaps —
    /// the swaps then complete the dish. Any uncovered shortfall, any
    /// swap aimed at a line that is not a shortfall, and this is nil:
    /// the grammar then names the problem lines instead of claiming a
    /// swap count that would not finish the job.
    public var completingSwapCount: Int? {
        let shortfalls = shortfallLines
        guard !shortfalls.isEmpty else { return nil }
        guard shortfalls.allSatisfy({ $0.state.isShort }) else { return nil }
        let covered = Set(swaps.map(\.coversLine))
        guard covered == Set(shortfalls.map(\.name)), swaps.count == shortfalls.count else {
            return nil
        }
        return swaps.count
    }

    // MARK: Display strings (the honesty rules live here)

    /// The fit line itself.
    ///
    /// - Every line sufficient: "10 of 10".
    /// - Every shortfall a validated swap covers: "9 of 10 · 1 swap" —
    ///   the count is the validated coverage, never an unbound integer.
    /// - Anything else: "7 recorded · check eggs and oil" — naming up to
    ///   two problem lines, then counting the rest.
    ///
    /// The grammar cannot produce a percentage or an unearned "you have
    /// everything": both properties are asserted by tests.
    public var lineText: String {
        let shortfalls = shortfallLines
        guard !shortfalls.isEmpty else { return "\(total) of \(total)" }

        // The swap grammar is earned only by a validated
        // complete-after-swaps result: every shortfall short, every one
        // covered. Two shortages plus one unrelated swap say "check eggs
        // and oil", never "complete with swap".
        if let swaps = completingSwapCount {
            let swapWord = swaps == 1 ? "swap" : "swaps"
            return "\(sufficientCount) of \(total) · \(swaps) \(swapWord)"
        }

        let names = shortfalls.map(\.name)
        let head = names.prefix(2).joined(separator: " and ")
        let tail = names.count > 2 ? " and \(names.count - 2) more" : ""
        return "\(sufficientCount) recorded · check \(head)\(tail)"
    }
}
