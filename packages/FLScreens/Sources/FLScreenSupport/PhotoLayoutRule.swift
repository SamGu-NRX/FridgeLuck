// FLScreenSupport — the photo layout rule.
//
// From Sam's round decision on PR #95: photo areas are 3:2 (width:height)
// and capped at 40% of screen height, so Tonight's primary action stays
// visible above the tab bar on first paint. Two numbers, one decision each;
// screens read them through this rule and never inline their own.
//
// Foundation-only so the arithmetic is Linux-testable. The values are named
// here rather than in FLDesignTokens because the base branch owns that
// package's API; if it lands photo layout tokens, this rule re-points at
// them and nothing else changes.

/// The layout rule every photo area in a FridgeLuck screen obeys.
public enum PhotoLayoutRule {

    /// 3:2 width:height — the aspect every photo area uses. (The round
    /// decision fixed 3:2, superseding Direction H's mock 4:5 crops.)
    public static let aspectRatio: Double = 1.5

    /// Photo height is capped at this fraction of the available height, so
    /// the pick's actions stay above the tab bar on first paint.
    public static let maxHeightFraction: Double = 0.40

    /// Photo height for a given width and available height. The 3:2 height
    /// for the width, capped at the height cap. Never negative; a
    /// degenerate input (zero width or height) yields zero, never a crash.
    public static func height(forWidth width: Double, availableHeight: Double) -> Double {
        guard width > 0, availableHeight > 0 else { return 0 }
        let idealHeight = width / aspectRatio
        let cap = availableHeight * maxHeightFraction
        return min(idealHeight, cap)
    }

    /// The reference device geometry the round decision was drawn against:
    /// the layout the mocks render at and the width Tonight's hero was
    /// sized to. One named pair so the cap and the hero ideal measure the
    /// same screen everywhere, instead of each call site guessing.
    public static let referenceScreenWidth: Double = 300
    public static let referenceScreenHeight: Double = 852

    /// The hero ideal: the 3:2 height for the reference width, capped once
    /// at 40% of the reference screen height. THE derivation for every
    /// screen-top photo area — Tonight's pick photo, the Recipe hero, Scan's
    /// analysing and problem photos, the Tour card's photo — so the areas
    /// render at one height and the cap is applied exactly once, against
    /// the screen, never against the photo frame itself. (Part 7 audit:
    /// the earlier per-site pattern re-derived the height inside each
    /// area's own frame, double-capping — 40% of the already-ideal
    /// height — and the areas rendered far short of 3:2. This named
    /// derivation is the one call a hero area makes.)
    public static var heroIdealHeight: Double {
        height(forWidth: referenceScreenWidth, availableHeight: referenceScreenHeight)
    }
}
