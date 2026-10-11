// FLScreenSupport — the saved-from-waste counter's display grammar.
//
// Shell S's Progress counters ("1.2 kg saved") and the quests candidate's
// week counters ("620 g food saved") state the same number: grams of food
// used before it spoiled. Both derive their display here so the two
// surfaces cannot drift apart, with the same shape of rules as
// FLFitSummary: numbers in, display strings out — nothing is scored,
// nothing is rounded up.
//
// Foundation-only, Sendable, Equatable: Linux-tested in
// FLScreenSupportTests.

import Foundation

/// Food saved from waste, in grams, with its one display form.
public struct FLSavedFoodLine: Equatable, Sendable {

    /// Grams of food used before it spoiled. Never negative — a malformed
    /// reading clamps to zero rather than rendering a debt.
    public let grams: Int

    public init(grams: Int) {
        self.grams = max(0, grams)
    }

    /// The display form: whole grams under a kilo ("620 g"), kilograms to
    /// one decimal at and above a kilo ("1.2 kg", "1.0 kg"). The fixed
    /// decimal form keeps the tabular numerals aligned.
    public var displayText: String {
        guard grams >= 1_000 else { return "\(grams) g" }
        return String(format: "%.1f kg", Double(grams) / 1_000.0)
    }
}
